import NIOCore

/// Joins two channels: what one reads, the other writes, with back-pressure (a side stops reading while its
/// partner cannot write) and half-close carried across. Modelled on swift-nio's NIOConnectProxy example
/// (Apache-2.0), changed so the two channels may live on different event loops (the SSH connection's and the
/// listener's): every call into the partner hops to the partner's loop, and each handler's state is only
/// touched on its own loop.
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var loop: (any EventLoop)?
    /// Before `handlerAdded`, calls from the partner wait here.
    private var pending: [(GlueHandler) -> Void] = []
    private var partnerWritable = true
    private var readPending = false

    static func pair(_ a: GlueHandler, _ b: GlueHandler) {
        a.partner = b
        b.partner = a
    }

    // MARK: calls from the partner (arrive on any loop)

    private func onMyLoop(_ body: @escaping (GlueHandler) -> Void) {
        guard let loop else {
            // Not added yet: the partner's loop is the only caller before that, and handlerAdded drains this.
            pending.append(body)
            return
        }
        if loop.inEventLoop { body(self) } else { loop.execute { body(self) } }
    }

    private func partnerWrite(_ data: NIOAny) {
        onMyLoop { $0.context?.write(data, promise: nil) }
    }

    private func partnerFlush() {
        onMyLoop { $0.context?.flush() }
    }

    private func partnerWritabilityChanged(_ writable: Bool) {
        onMyLoop { me in
            me.partnerWritable = writable
            if writable, me.readPending, let context = me.context {
                me.readPending = false
                context.read()
            }
        }
    }

    private func partnerInputClosed() {
        onMyLoop { $0.context?.close(mode: .output, promise: nil) }
    }

    private func partnerClosed() {
        onMyLoop { $0.context?.close(promise: nil) }
    }

    // MARK: own channel

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        self.loop = context.eventLoop
        let waiting = pending
        pending = []
        for body in waiting { body(self) }
        // A channel that is already unwritable when joined tells its partner at once.
        if !context.channel.isWritable { partner?.partnerWritabilityChanged(false) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClosed()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            partner?.partnerInputClosed()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        partner?.partnerWritabilityChanged(context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if partnerWritable {
            context.read()
        } else {
            readPending = true
        }
    }
}
