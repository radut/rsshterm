import NIO
@preconcurrency import NIOSSH

// rSSH patch (see PATCHES.md): agent forwarding on the client side. The server opens an "auth-agent@openssh.com"
// channel for every agent client on its side once a session asked for it (`withPTY(_:environment:forwardAgent:perform:)`);
// the handler set here serves each such channel.

/// Called on the channel's event loop for every agent channel the server opens. The channel's pipeline already
/// turns `SSHChannelData` into `ByteBuffer` both ways: add a handler that reads ssh-agent requests and writes the
/// replies. A failed future refuses the channel.
public typealias SSHAgentChannelHandler = @Sendable (Channel) -> EventLoopFuture<Void>

extension SSHClient {
    /// Serves agent channels with `handler`; nil (the default) refuses them. Set it before the session that asks for
    /// forwarding starts. It applies to this connection only, not to one made by a reconnect.
    public func setAgentForwardingHandler(_ handler: SSHAgentChannelHandler?) {
        session.inboundChannelHandler.agentHandler.withLockedValue { $0 = handler }
    }
}
