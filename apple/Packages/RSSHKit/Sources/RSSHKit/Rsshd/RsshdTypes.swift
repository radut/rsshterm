import Foundation

/// The constants of rsshd/PROTOCOL.md (version 1, frozen).
public enum RsshdProtocol {
    public static let version = 1
    /// A longer line closes the connection (both sides).
    public static let maxLineBytes = 1 << 20
    public static let client = "rSshTerm/1.0"
}

/// A typed failure from the daemon. Unknown codes pass through, so a newer daemon's codes still show.
public struct RsshdError: Error, Equatable, Sendable, Decodable {
    public struct Code: RawRepresentable, Hashable, Sendable, Decodable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }

        public static let badRequest = Code(rawValue: "bad_request")
        public static let unsupportedVersion = Code(rawValue: "unsupported_version")
        public static let unknownOp = Code(rawValue: "unknown_op")
        public static let notFound = Code(rawValue: "not_found")
        public static let backendError = Code(rawValue: "backend_error")
        public static let notImplemented = Code(rawValue: "not_implemented")
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

/// The reply to `hello`: what the server has. Missing fields take empty values, so an older or newer daemon decodes.
public struct RsshdHello: Decodable, Equatable, Sendable {
    public struct Caps: Decodable, Equatable, Sendable {
        public var reptyr: String
        public var sudoReptyr: Bool
        public var ptraceScope: Int
        public var linger: Bool
        public var os: String

        public init(reptyr: String = "", sudoReptyr: Bool = false, ptraceScope: Int = -1, linger: Bool = false,
                    os: String = "") {
            self.reptyr = reptyr
            self.sudoReptyr = sudoReptyr
            self.ptraceScope = ptraceScope
            self.linger = linger
            self.os = os
        }

        private enum CodingKeys: String, CodingKey {
            case reptyr, linger, os, sudoReptyr = "sudo_reptyr", ptraceScope = "ptrace_scope"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(reptyr: c.lenient(String.self, .reptyr) ?? "", sudoReptyr: c.lenient(Bool.self, .sudoReptyr) ?? false,
                      ptraceScope: c.lenient(Int.self, .ptraceScope) ?? -1, linger: c.lenient(Bool.self, .linger) ?? false,
                      os: c.lenient(String.self, .os) ?? "")
        }
    }

    public var proto: Int
    public var version: String
    /// Backend name -> its version ("tmux": "3.4").
    public var backends: [String: String]
    public var defaultBackend: String
    public var caps: Caps
    /// Names of the doctor checks that failed ("reptyr", "screen", …).
    public var missing: [String]

    public init(proto: Int = RsshdProtocol.version, version: String, backends: [String: String], defaultBackend: String,
                caps: Caps = Caps(), missing: [String] = []) {
        self.proto = proto
        self.version = version
        self.backends = backends
        self.defaultBackend = defaultBackend
        self.caps = caps
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey {
        case proto, version, backends, caps, missing, defaultBackend = "default_backend"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(proto: c.lenient(Int.self, .proto) ?? RsshdProtocol.version,
                  version: c.lenient(String.self, .version) ?? "",
                  backends: c.lenient([String: String].self, .backends) ?? [:],
                  defaultBackend: c.lenient(String.self, .defaultBackend) ?? "tmux",
                  caps: c.lenient(Caps.self, .caps) ?? Caps(), missing: c.lenient([String].self, .missing) ?? [])
    }
}

/// One session the daemon manages.
public struct RsshdSession: Decodable, Equatable, Sendable, Identifiable {
    public struct Deadlines: Decodable, Equatable, Sendable {
        /// When the session closes if nothing happens; nil when the idle timeout is off.
        public var idle: Date?
        public var hard: Date?

        public init(idle: Date? = nil, hard: Date? = nil) {
            self.idle = idle
            self.hard = hard
        }

        private enum CodingKeys: String, CodingKey { case idle, hard }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(idle: c.date(.idle), hard: c.date(.hard))
        }
    }

    public struct Timeouts: Decodable, Equatable, Sendable {
        public var idleS: Int
        public var hardS: Int
        public var finishWork: Bool
        public var warnLeadS: Int

        private enum CodingKeys: String, CodingKey {
            case idleS = "idle_s", hardS = "hard_s", finishWork = "finish_work", warnLeadS = "warn_lead_s"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            idleS = c.lenient(Int.self, .idleS) ?? 0
            hardS = c.lenient(Int.self, .hardS) ?? 0
            finishWork = c.lenient(Bool.self, .finishWork) ?? false
            warnLeadS = c.lenient(Int.self, .warnLeadS) ?? 0
        }
    }

    public var id: String
    public var name: String
    public var backend: String
    public var created: Date?
    public var lastActivity: Date?
    public var attachedClients: Int
    public var state: String
    public var deadlines: Deadlines
    public var timeouts: Timeouts?
    public var fgRunning: Bool
    /// The program in the foreground ("bash", "htop").
    public var fgCommand: String
    public var altScreen: Bool
    /// The foreground program, its arguments (secrets out) and folder, for the tab title; nil from older daemons.
    public var pane: PaneReport?

    public init(id: String, name: String = "", backend: String = "tmux", created: Date? = nil, lastActivity: Date? = nil,
                attachedClients: Int = 0, state: String = "active", deadlines: Deadlines = Deadlines(),
                fgRunning: Bool = false, fgCommand: String = "", altScreen: Bool = false) {
        self.id = id
        self.name = name
        self.backend = backend
        self.created = created
        self.lastActivity = lastActivity
        self.attachedClients = attachedClients
        self.state = state
        self.deadlines = deadlines
        self.timeouts = nil
        self.fgRunning = fgRunning
        self.fgCommand = fgCommand
        self.altScreen = altScreen
        self.pane = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, backend, created, state, deadlines, timeouts, pane
        case lastActivity = "last_activity", attachedClients = "attached_clients", fgRunning = "fg_running"
        case fgCommand = "fg_command", altScreen = "alt_screen"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? ""
        backend = c.lenient(String.self, .backend) ?? "tmux"
        created = c.date(.created)
        lastActivity = c.date(.lastActivity)
        attachedClients = c.lenient(Int.self, .attachedClients) ?? 0
        state = c.lenient(String.self, .state) ?? "active"
        deadlines = c.lenient(Deadlines.self, .deadlines) ?? Deadlines()
        timeouts = c.lenient(Timeouts.self, .timeouts)
        fgRunning = c.lenient(Bool.self, .fgRunning) ?? false
        fgCommand = c.lenient(String.self, .fgCommand) ?? ""
        altScreen = c.lenient(Bool.self, .altScreen) ?? false
        pane = c.lenient(PaneReport.self, .pane)
    }
}

/// One of the user's own multiplexer sessions: attach-only, no timeouts.
public struct RsshdForeign: Decodable, Equatable, Sendable, Identifiable {
    public var name: String
    public var backend: String
    public var attachedClients: Int
    /// The command that attaches it (`["tmux", "attach", "-t", "main"]`).
    public var attach: [String]
    public var id: String { backend + ":" + name }

    public init(name: String, backend: String, attachedClients: Int, attach: [String]) {
        self.name = name
        self.backend = backend
        self.attachedClients = attachedClients
        self.attach = attach
    }

    private enum CodingKeys: String, CodingKey { case name, backend, attach, attachedClients = "attached_clients" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: c.lenient(String.self, .name) ?? "", backend: c.lenient(String.self, .backend) ?? "tmux",
                  attachedClients: c.lenient(Int.self, .attachedClients) ?? 0, attach: c.lenient([String].self, .attach) ?? [])
    }
}

/// The reply to `list`.
public struct RsshdList: Decodable, Equatable, Sendable {
    public var sessions: [RsshdSession]
    public var foreign: [RsshdForeign]

    public init(sessions: [RsshdSession] = [], foreign: [RsshdForeign] = []) {
        self.sessions = sessions
        self.foreign = foreign
    }

    private enum CodingKeys: String, CodingKey { case sessions, foreign }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessions: c.lenient([RsshdSession].self, .sessions) ?? [],
                  foreign: c.lenient([RsshdForeign].self, .foreign) ?? [])
    }
}

/// The reply to `create`.
public struct RsshdCreated: Decodable, Equatable, Sendable {
    public var id: String
    public var session: RsshdSession
}

/// The reply to `status`.
struct RsshdStatusResult: Decodable { var session: RsshdSession }

/// The reply to `health`.
public struct RsshdHealth: Decodable, Equatable, Sendable {
    public struct Backend: Decodable, Equatable, Sendable {
        public var name: String
        public var version: String
        private enum CodingKeys: String, CodingKey { case name, version }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lenient(String.self, .name) ?? ""
            version = c.lenient(String.self, .version) ?? ""
        }
    }

    public var version: String
    public var uptimeS: Int
    public var backend: Backend
    public var sessions: Int
    public var lastError: String

    private enum CodingKeys: String, CodingKey {
        case version, backend, sessions, uptimeS = "uptime_s", lastError = "last_error"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(String.self, .version) ?? ""
        uptimeS = c.lenient(Int.self, .uptimeS) ?? 0
        backend = try c.decode(Backend.self, forKey: .backend)
        sessions = c.lenient(Int.self, .sessions) ?? 0
        lastError = c.lenient(String.self, .lastError) ?? ""
    }
}

// MARK: request arguments

struct RsshdHelloArgs: Encodable {
    var client: String
    var proto: [Int]
}

public struct RsshdListArgs: Encodable, Sendable {
    public var includeForeign: Bool
    public init(includeForeign: Bool) { self.includeForeign = includeForeign }
    private enum CodingKeys: String, CodingKey { case includeForeign = "include_foreign" }
}

/// `create`; nil fields stay out of the line, so the daemon's defaults apply.
public struct RsshdCreateArgs: Encodable, Sendable {
    public var name: String?
    public var backend: String?
    public var cwd: String?
    public var command: String?
    public var cols: Int?
    public var rows: Int?
    /// Left out: the daemon's own defaults (its config.toml).
    public var timeouts: SessionTimeouts?

    public init(name: String? = nil, backend: String? = nil, cwd: String? = nil, command: String? = nil,
                cols: Int? = nil, rows: Int? = nil, timeouts: SessionTimeouts? = nil) {
        self.timeouts = timeouts
        self.name = name
        self.backend = backend
        self.cwd = cwd
        self.command = command
        self.cols = cols
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey { case name, backend, cwd, command, cols, rows, timeouts }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(backend, forKey: .backend)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(cols, forKey: .cols)
        try c.encodeIfPresent(rows, forKey: .rows)
        try c.encodeIfPresent(timeouts.map { RsshdTimeoutArgs($0) }, forKey: .timeouts)
    }
}

struct RsshdIDArgs: Encodable { var id: String }
struct RsshdNoArgs: Encodable {}

struct RsshdSubscribeArgs: Encodable {
    var pane: Bool
}

// MARK: lenient decoding

extension KeyedDecodingContainer {
    /// The value, or nil when it is absent or of another type: unknown or changed fields never fail a reply.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// An RFC 3339 time (Go writes up to nine fraction digits), or nil.
    func date(_ key: Key) -> Date? {
        lenient(String.self, key).flatMap(RFC3339.date(from:))
    }
}

/// RFC 3339 times as Go's encoding/json writes them; ISO8601DateFormatter takes at most three fraction digits.
enum RFC3339 {
    static func date(from text: String) -> Date? {
        var whole = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            fraction = Double("0" + text[dot..<end]) ?? 0
            whole = String(text[..<dot] + text[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: whole).map { $0.addingTimeInterval(fraction) }
    }
}
