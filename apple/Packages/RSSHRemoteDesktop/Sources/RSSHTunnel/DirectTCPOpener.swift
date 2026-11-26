import NIOCore
import NIOPosix

/// A "forward" that is a plain TCP connection from this device: remote desktops set to connect directly (no SSH)
/// go through the same local listener, so the viewer code is the same either way.
public struct DirectTCPOpener: DirectTCPIPOpener {
    public var connectTimeout: TimeAmount

    public init(connectTimeout: TimeAmount = .seconds(15)) { self.connectTimeout = connectTimeout }

    public func openForward(to host: String, port: Int, originator: SocketAddress?,
                            initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>) async throws -> any Channel {
        try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(connectTimeout)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .channelInitializer(initialize)
            .connect(host: host, port: port).get()
    }
}
