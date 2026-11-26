import Foundation

/// Where sessions live on a server: in the daemon's tmux or screen, or nowhere (a plain shell).
public enum SessionBackend: String, Codable, CaseIterable, Sendable {
    case tmux, screen, off

    public var title: String {
        switch self {
        case .tmux: "tmux"
        case .screen: "screen"
        case .off: "Off (plain shell)"
        }
    }
}

/// Which backend a server's next session uses.
public enum SessionDaemonPolicy {
    /// The server's own choice wins; without one, the default from Settings.
    public static func backend(server: SessionBackend?, global: SessionBackend) -> SessionBackend {
        server ?? global
    }
}

/// What the app asks for when it connects with the daemon on.
public struct RsshdConnectRequest: Equatable, Sendable {
    public var backend: SessionBackend
    /// Re-attach this session (a reconnect); nil creates a new one.
    public var attachTo: String?
    public var cols: Int
    public var rows: Int
    /// A new session first looks for kept ones not open here (`openHere`), unless this is `.new`.
    public var resume: ResumeChoice = .new
    /// rsshd ids already attached in tabs on this device.
    public var openHere: Set<String> = []
    /// Limits for a session this connect makes; nil leaves them to the daemon's config.
    public var timeouts: SessionTimeouts?

    public init(backend: SessionBackend, attachTo: String?, cols: Int, rows: Int) {
        self.backend = backend
        self.attachTo = attachTo
        self.cols = cols
        self.rows = rows
    }
}

/// A session the terminal can attach to.
public struct RsshdAttachment: Equatable, Sendable {
    public var id: String
    /// The backend it runs in ("tmux").
    public var backend: String
    public var hello: RsshdHello
    /// True when this connect made it, false when it was there already.
    public var created: Bool
    /// Something the user should know (the chosen backend was missing), or nil.
    public var note: String?
    /// More sessions the user picked to resume; the app opens each in its own tab.
    public var alsoResume: [String] = []
    /// Every rSSH session id on the server when this connect listed them (stale vault entries go), else nil.
    public var listedIDs: [String]?

    public init(id: String, backend: String, hello: RsshdHello, created: Bool, note: String? = nil) {
        self.id = id
        self.backend = backend
        self.hello = hello
        self.created = created
        self.note = note
    }

    /// "rsshd 1.0.2 · tmux 3.4" for the connect chip.
    public var summary: String {
        let version = hello.backends[backend].map { " \($0)" } ?? ""
        let update = RsshdRelease.isOlder(hello.version) ? " · update \(RsshdRelease.latest)" : ""
        return "rSshD \(hello.version) · \(backend)\(version)\(update)"
    }
}

/// Why the daemon is not used: the shell opens plain, as without it.
public enum RsshdUnavailable: Equatable, Sendable {
    case notInstalled
    case failed(String)

    public var message: String {
        switch self {
        case .notInstalled: "Sessions not kept: rSshD not installed"
        case .failed(let why): "Sessions not kept: \(why)"
        }
    }
}

/// The user's answer to "Sessions on <server>".
public enum RsshdChoice: Equatable, Sendable {
    case new
    /// Attach these, the first in this tab.
    case resume([String])
}

/// Asks the user which kept sessions to resume.
public typealias RsshdChooser = @Sendable ([RsshdSession]) async -> RsshdChoice

public enum RsshdConnectOutcome: Equatable, Sendable {
    case attach(RsshdAttachment)
    /// Open a plain shell.
    case plain(RsshdUnavailable)
    /// The session to re-attach is gone from the server (closed, timed out or its shell exited).
    case sessionEnded(id: String)
}

/// hello, then status (reconnect) or create (new session). Any failure before attaching means a plain shell.
public enum RsshdConnectFlow {
    public static func run(_ request: RsshdConnectRequest, client: RsshdClient,
                           choose: RsshdChooser? = nil) async -> RsshdConnectOutcome {
        let hello: RsshdHello
        do { hello = try await client.hello() } catch { return .plain(unavailable(error)) }
        var listed: [String]?
        if request.attachTo == nil, request.resume != .new, let list = try? await client.list(includeForeign: false) {
            listed = list.sessions.map(\.id)
            let candidates = list.sessions.filter { !request.openHere.contains($0.id) }
                .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            if let picked = await pick(from: candidates, request.resume, choose: choose), let first = picked.first,
               let session = candidates.first(where: { $0.id == first }) {
                var attachment = RsshdAttachment(id: first, backend: session.backend, hello: hello, created: false)
                attachment.alsoResume = Array(picked.dropFirst())
                attachment.listedIDs = listed
                return .attach(attachment)
            }
        }
        if let id = request.attachTo {
            do {
                let session = try await client.status(id: id)
                return .attach(RsshdAttachment(id: id, backend: session.backend, hello: hello, created: false))
            } catch RsshdClientError.server(let error) where error.code == .notFound {
                return .sessionEnded(id: id)
            } catch {
                return .plain(unavailable(error))
            }
        }
        let (backend, note) = backendFor(request.backend, from: hello)
        do {
            let created = try await client.create(RsshdCreateArgs(backend: backend, cols: request.cols, rows: request.rows,
                                                                    timeouts: request.timeouts))
            var attachment = RsshdAttachment(id: created.id, backend: created.session.backend, hello: hello,
                                             created: true, note: note)
            attachment.listedIDs = listed.map { $0 + [created.id] }
            return .attach(attachment)
        } catch {
            return .plain(unavailable(error))
        }
    }

    /// The ids to resume, or nil for a new session.
    private static func pick(from candidates: [RsshdSession], _ resume: ResumeChoice,
                             choose: RsshdChooser?) async -> [String]? {
        guard !candidates.isEmpty else { return nil }
        switch resume {
        case .new: return nil
        case .last: return [candidates[0].id]
        case .ask:
            guard let choose, case .resume(let ids) = await choose(candidates), !ids.isEmpty else { return nil }
            return ids
        }
    }

    /// The wanted backend when the server has it; else its default, with a note. A daemon refuses a backend it
    /// does not run, so asking anyway would only fail the session.
    static func backendFor(_ wanted: SessionBackend, from hello: RsshdHello) -> (String, String?) {
        if hello.backends[wanted.rawValue] != nil { return (wanted.rawValue, nil) }
        let fallback = hello.defaultBackend
        return (fallback, "\(wanted.rawValue) is not available on this server; using \(fallback)")
    }

    /// The reason a failed call means a plain shell.
    public static func unavailable(_ error: any Error) -> RsshdUnavailable {
        switch error as? RsshdClientError {
        case .closed(let reason as RsshdExit)? where reason.status == 127:
            return .notInstalled
        case .closed(let reason as RsshdExit)?:
            return .failed("rsshd rpc ended with exit status \(reason.status)")
        case .closed?:
            return .failed("rsshd rpc ended")
        case .server(let error)?:
            return .failed(error.message.isEmpty ? error.code.rawValue : error.message)
        case .timedOut?:
            return .failed("rSshD did not answer")
        case .protocolViolation(let what)?:
            return .failed("rSshD answered something unexpected (\(what))")
        case nil:
            return .failed(error.localizedDescription)
        }
    }
}
