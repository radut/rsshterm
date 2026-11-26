import Foundation

/// Why a call to the daemon did not return a result.
public enum RsshdClientError: Error, Sendable {
    /// The daemon answered with an error.
    case server(RsshdError)
    /// The channel ended; `reason` is what ended it (an `RsshdExit`, a transport error) or nil at a clean end.
    case closed(reason: (any Error)?)
    case timedOut
    /// A line could not be read or a result had the wrong shape.
    case protocolViolation(String)
}

extension RsshdClientError: Equatable {
    public static func == (lhs: RsshdClientError, rhs: RsshdClientError) -> Bool {
        switch (lhs, rhs) {
        case (.server(let a), .server(let b)): a == b
        case (.closed, .closed), (.timedOut, .timedOut): true
        case (.protocolViolation(let a), .protocolViolation(let b)): a == b
        default: false
        }
    }
}

/// The exit status of the `rsshd rpc` command, when its channel ends with one (127: rsshd is not installed).
public struct RsshdExit: Error, Equatable, Sendable {
    public let status: Int
    public init(status: Int) { self.status = status }
}

/// An event after `subscribe`.
public struct RsshdEvent: Equatable, Sendable {
    public var name: String
    public var data: Data

    /// A `pane` event (after `subscribe(pane: true)`): the session's program, arguments and folder changed.
    public var pane: (id: String, report: PaneReport)? {
        struct Body: Decodable {
            var id: String
            var pane: PaneReport
        }
        guard name == "pane", let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        return (body.id, body.pane)
    }
}

/// Talks to `rsshd rpc` over any byte pipe (an SSH exec channel in the app, a fake in tests). Client-chosen ids
/// match replies that come out of order; events are dropped unless `subscribe` was called.
public actor RsshdClient {
    public typealias Send = @Sendable (Data) async throws -> Void

    private let sendLine: Send
    private let timeout: Duration
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var finished: RsshdClientError?
    private var events: AsyncStream<RsshdEvent>.Continuation?
    private var reader: Task<Void, Never>?

    public init(send: @escaping Send, incoming: AsyncThrowingStream<[UInt8], any Error>,
                timeout: Duration = .seconds(10)) {
        self.sendLine = send
        self.timeout = timeout
        Task { await self.startReading(incoming) }
    }

    // MARK: ops

    public func hello() async throws -> RsshdHello {
        let hello = try await call("hello", RsshdHelloArgs(client: RsshdProtocol.client, proto: [RsshdProtocol.version]),
                                   as: RsshdHello.self)
        guard hello.proto == RsshdProtocol.version else {
            throw RsshdClientError.server(RsshdError(code: .unsupportedVersion, message: "daemon speaks \(hello.proto)"))
        }
        return hello
    }

    public func list(includeForeign: Bool) async throws -> RsshdList {
        try await call("list", RsshdListArgs(includeForeign: includeForeign), as: RsshdList.self)
    }

    public func create(_ args: RsshdCreateArgs) async throws -> RsshdCreated {
        try await call("create", args, as: RsshdCreated.self)
    }

    public func status(id: String) async throws -> RsshdSession {
        try await call("status", RsshdIDArgs(id: id), as: RsshdStatusResult.self).session
    }

    /// New idle and hard limits for a running session; the daemon recomputes its deadlines at once.
    public func setTimeouts(id: String, _ timeouts: SessionTimeouts) async throws -> RsshdSession {
        try await call("set_timeouts", RsshdTimeoutArgs(id: id, timeouts), as: RsshdStatusResult.self).session
    }

    public func close(id: String) async throws {
        _ = try await call("close", RsshdIDArgs(id: id))
    }

    public func health() async throws -> RsshdHealth {
        try await call("health", RsshdNoArgs(), as: RsshdHealth.self)
    }

    /// Events from now on, until the channel ends.
    /// `pane: true` adds `pane` events (tab titles); daemons before them ignore the flag.
    public func subscribe(pane: Bool = false) async throws -> AsyncStream<RsshdEvent> {
        let (stream, continuation) = AsyncStream<RsshdEvent>.makeStream()
        events = continuation
        if pane {
            _ = try await call("subscribe", RsshdSubscribeArgs(pane: true))
        } else {
            _ = try await call("subscribe", RsshdNoArgs())
        }
        return stream
    }

    // MARK: calls

    private func call<T: Decodable>(_ op: String, _ args: some Encodable & Sendable, as type: T.Type) async throws -> T {
        let data = try await call(op, args)
        do { return try RsshdCodec.decodeResult(type, from: data) } catch {
            throw RsshdClientError.protocolViolation("\(op): \(error)")
        }
    }

    private func call(_ op: String, _ args: some Encodable & Sendable) async throws -> Data {
        if let finished { throw finished }
        let id = nextID
        nextID += 1
        let line = try RsshdCodec.request(id: id, op: op, args: args)
        let wait = timeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            await self?.fail(id, with: .timedOut)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [sendLine] in
                do { try await sendLine(line) } catch { await self.fail(id, with: .closed(reason: error)) }
            }
        }
    }

    private func fail(_ id: Int, with error: RsshdClientError) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: reading

    private func startReading(_ incoming: AsyncThrowingStream<[UInt8], any Error>) {
        reader = Task { [weak self] in
            var buffer = RsshdLineBuffer()
            do {
                for try await chunk in incoming {
                    for line in try buffer.append(chunk) { await self?.receive(line) }
                }
                await self?.finish(.closed(reason: nil))
            } catch let error as RsshdCodecError {
                await self?.finish(.protocolViolation("\(error)"))
            } catch {
                await self?.finish(.closed(reason: error))
            }
        }
    }

    private func receive(_ line: Data) {
        switch try? RsshdCodec.decode(line: line) {
        case .reply(let id, .success(let data))?:
            pending.removeValue(forKey: id)?.resume(returning: data)
        case .reply(let id, .failure(let error))?:
            pending.removeValue(forKey: id)?.resume(throwing: RsshdClientError.server(error))
        case .event(let name, let data)?:
            events?.yield(RsshdEvent(name: name, data: data))
        case nil:
            break  // Not ours to answer: the protocol ignores what it cannot read rather than guessing an id.
        }
    }

    private func finish(_ error: RsshdClientError) {
        finished = error
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending = [:]
        events?.finish()
    }
}
