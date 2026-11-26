import Citadel
import NIOCore
import NIOSSH

/// The app's opener: a direct-tcpip channel of an authenticated Citadel connection (the same request
/// `SSHClient.jump` makes for a jump host). A client reached through jump hosts forwards from the last hop.
///
/// `SSHClient` is not `Sendable` (Citadel 0.12); its channel creation hops onto the connection's event loop, so
/// calling it from the forwarder's loops is safe, hence `@unchecked`.
public struct CitadelForwardOpener: DirectTCPIPOpener, @unchecked Sendable {
    public let client: SSHClient

    public init(client: SSHClient) { self.client = client }

    public func openForward(to host: String, port: Int, originator: SocketAddress?,
                            initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>) async throws -> any Channel {
        // RFC 4254 7.2 wants the originator's address; Citadel's jump sends a placeholder, so does this when the
        // local peer has no IP address.
        let origin = try originator ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)
        return try await client.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin),
            initialize: initialize)
    }
}
