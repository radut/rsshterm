import Foundation
import NIOCore
import NIOPosix
import Synchronization

/// Anything that opens a direct-tcpip channel ("connect to host:port from over there"): a Citadel `SSHClient` in
/// the app, a plain TCP connection in tests. The returned channel reads and writes `ByteBuffer`s.
public protocol DirectTCPIPOpener: Sendable {
    func openForward(to host: String, port: Int, originator: SocketAddress?,
                     initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>) async throws -> any Channel
}

/// `ssh -L 127.0.0.1:<port>:<host>:<port>`: a listener on this device's loopback whose every connection becomes a
/// direct-tcpip channel of one SSH connection, bytes glued both ways. Remote-desktop clients (RoyalVNCKit,
/// FreeRDP, macOS Screen Sharing.app) open their own sockets, so a local listener is what all of them can use.
///
/// Any process on this device can connect to the listener while it is open, as with `ssh -L`; the screen's own
/// authentication (VNC password, macOS account, RDP login) still applies behind it. To keep that window small,
/// `acceptLimit` stops listening after that many connections (the in-app viewer opens exactly one, so it passes 1
/// and connects right after start), and the owner closes the forwarder when the screen closes. TCP loopback has
/// no peer credentials to check (SO_PEERCRED/LOCAL_PEERCRED are for Unix sockets, which the clients do not take).
public final class LocalPortForwarder: Sendable {
    public enum StartError: Error, Equatable, Sendable, LocalizedError {
        case notLoopback(String)
        case invalidTargetPort(Int)
        case invalidAcceptLimit(Int)

        public var errorDescription: String? {
            switch self {
            case .notLoopback(let host): "A tunnel listens on this device only (127.0.0.1 or ::1), not on \(host)."
            case .invalidTargetPort(let port): "Port \(port) is not a port from 1 to 65535."
            case .invalidAcceptLimit(let n): "A tunnel must accept at least one connection, not \(n)."
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case forwardOpened
        /// The SSH server refused or could not reach the target; the text is its reason.
        case forwardFailed(String)
        case forwardClosed
    }

    public let localPort: Int
    public let targetHost: String
    public let targetPort: Int

    private let server: any Channel
    private let state: Mutex<State>

    struct State {
        var open: [ObjectIdentifier: any Channel] = [:]
        var events: [Event] = []
        var closed = false
        var accepted = 0
        var acceptLimit: Int?
    }

    /// Keeps the last events for status and tests; older ones are dropped.
    static let eventLimit = 64

    private init(server: any Channel, targetHost: String, targetPort: Int) {
        self.server = server
        self.localPort = server.localAddress?.port ?? 0
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.state = Mutex(State())
    }

    /// Listens on `bindHost:bindPort` (0: any free port, see `localPort`) and forwards to `targetHost:targetPort`
    /// as the SSH server sees it ("localhost" is the server itself).
    public static func start(opener: any DirectTCPIPOpener, targetHost: String, targetPort: Int,
                             bindHost: String = "127.0.0.1", bindPort: Int = 0, acceptLimit: Int? = nil,
                             group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton)
        async throws -> LocalPortForwarder {
        guard ["127.0.0.1", "::1", "localhost"].contains(bindHost) else { throw StartError.notLoopback(bindHost) }
        guard (1...65535).contains(targetPort) else { throw StartError.invalidTargetPort(targetPort) }
        if let acceptLimit, acceptLimit < 1 { throw StartError.invalidAcceptLimit(acceptLimit) }

        // The forwarder and its connections share one state box; the forwarder is built after the bind.
        let box = Box()
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            // Nothing is read from the local side before the SSH side exists to take it.
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { local in
                guard let forwarder = box.forwarder else { return local.close() }
                return forwarder.accept(local, opener: opener)
            }
            .bind(host: bindHost, port: bindPort).get()
        let forwarder = LocalPortForwarder(server: server, targetHost: targetHost, targetPort: targetPort)
        forwarder.state.withLock { $0.acceptLimit = acceptLimit }
        box.forwarder = forwarder
        return forwarder
    }

    /// Stops listening and closes every forwarded connection.
    public func close() async {
        let open = state.withLock { s -> [any Channel] in
            s.closed = true
            return Array(s.open.values)
        }
        try? await server.close()
        for channel in open { try? await channel.close() }
    }

    public func recentEvents() async -> [Event] { state.withLock { $0.events } }

    public var openConnections: Int { state.withLock { $0.open.count } }

    /// False once `close()` ran or `acceptLimit` connections were taken: nothing new can connect.
    public var isListening: Bool { server.isActive }

    // MARK: per connection

    private func accept(_ local: any Channel, opener: any DirectTCPIPOpener) -> EventLoopFuture<Void> {
        let (admitted, limitReached) = state.withLock { s -> (Bool, Bool) in
            guard !s.closed, s.accepted < (s.acceptLimit ?? .max) else { return (false, false) }
            s.accepted += 1
            return (true, s.accepted == s.acceptLimit)
        }
        guard admitted, track(local) else { return local.close() }
        // The limit is reached: stop listening, so nothing else on this device can connect. Not from inside this
        // initializer (closing the server channel now would drop the child it is still accepting): once this
        // connection's forward is opened or failed.
        let stopListening: @Sendable () -> Void = { [server] in if limitReached { server.close(promise: nil) } }
        let loop = local.eventLoop
        let localGlue = GlueHandler()
        let remoteGlue = GlueHandler()
        GlueHandler.pair(localGlue, remoteGlue)
        let originator = local.remoteAddress
        local.closeFuture.whenComplete { [weak self] _ in self?.untrack(local) }

        // The local glue is in place before the SSH side exists, so the server's first bytes (an RFB banner comes
        // at once) always find it. The forward opens after the initializer returns: the local channel is only
        // registered (and can only be read) once the initializer's future completes.
        return local.pipeline.addHandler(localGlue).map { [targetHost, targetPort] in
            loop.makeFutureWithTask {
                try await opener.openForward(to: targetHost, port: targetPort, originator: originator) { remote in
                    remote.pipeline.addHandler(remoteGlue)
                }
            }.whenComplete { result in
                stopListening()
                switch result {
                case .failure(let error):
                    self.record(.forwardFailed(String(describing: error)))
                    local.close(promise: nil)
                case .success(let remote):
                    self.record(.forwardOpened)
                    remote.closeFuture.whenComplete { _ in self.record(.forwardClosed) }
                    // Track the SSH side too, so close() reaches it even when the local side is already gone.
                    if !self.track(remote) { remote.close(promise: nil) }
                    remote.closeFuture.whenComplete { [weak self] _ in self?.untrack(remote) }
                    // Reading starts now that there is somewhere to send the bytes.
                    local.setOption(.autoRead, value: true).whenFailure { _ in local.close(promise: nil) }
                }
            }
        }
    }

    private func track(_ channel: any Channel) -> Bool {
        state.withLock { s in
            guard !s.closed else { return false }
            s.open[ObjectIdentifier(channel)] = channel
            return true
        }
    }

    private func untrack(_ channel: any Channel) {
        _ = state.withLock { $0.open.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    private func record(_ event: Event) {
        state.withLock { s in
            s.events.append(event)
            if s.events.count > Self.eventLimit { s.events.removeFirst(s.events.count - Self.eventLimit) }
        }
    }

    /// Set once, right after the bind; read by connections that arrive (none can before it is set: the
    /// initializer only runs for accepted children, and the box is filled before `start` returns).
    private final class Box: @unchecked Sendable {
        private let lock = Mutex<LocalPortForwarder?>(nil)
        var forwarder: LocalPortForwarder? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }
}
