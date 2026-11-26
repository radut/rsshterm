import Foundation
import NIOCore
import NIOPosix
import Synchronization
@testable import RSSHTunnel

/// The library's `DirectTCPOpener` (no SSH), recording what it was asked to open.
final class PlainTCPOpener: DirectTCPIPOpener {
    struct Request: Equatable { var host: String; var port: Int }
    private let seen = Mutex<[Request]>([])
    var requests: [Request] { seen.withLock { $0 } }

    func openForward(to host: String, port: Int, originator: SocketAddress?,
                     initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>) async throws -> any Channel {
        seen.withLock { $0.append(Request(host: host, port: port)) }
        return try await DirectTCPOpener().openForward(to: host, port: port, originator: originator,
                                                       initialize: initialize)
    }
}

/// An SSH server that answers every direct-tcpip request with "administratively prohibited".
struct FailingOpener: DirectTCPIPOpener {
    struct Refused: Error, CustomStringConvertible { var description: String { "administratively prohibited" } }
    func openForward(to host: String, port: Int, originator: SocketAddress?,
                     initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>) async throws -> any Channel {
        throw Refused()
    }
}

/// Echoes every byte back, closing its side when the client half-closes.
struct EchoServer {
    let channel: any Channel
    var port: Int { channel.localAddress!.port! }

    static func start() async throws -> EchoServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
            .bind(host: "127.0.0.1", port: 0).get()
        return EchoServer(channel: channel)
    }

    func close() async { try? await channel.close() }

    final class Echo: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.writeAndFlush(data, promise: nil)
        }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case ChannelEvent.inputClosed = event { context.close(mode: .output, promise: nil) }
        }
    }
}

enum TCPProbe {
    struct Timeout: Error {}

    static func connect(port: Int) async throws -> any Channel {
        try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: port).get()
    }

    /// Sends `send`, then reads until `expect` bytes arrived or the other side closed; at most `seconds`.
    static func exchange(port: Int, send: String, expect: Int, seconds: Int64 = 10) async throws -> String {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let done = loop.makePromise(of: String.self)
        let channel = try await ClientBootstrap(group: loop)
            .channelInitializer { $0.pipeline.addHandler(Collector(expect: expect, done: done)) }
            .connect(host: "127.0.0.1", port: port).get()
        let timeout = loop.scheduleTask(in: .seconds(seconds)) { done.fail(Timeout()) }
        // A forwarder that refuses the connection may close it before this write lands: what arrived is the answer.
        if !send.isEmpty { try? await channel.writeAndFlush(ByteBuffer(string: send)) }
        defer { timeout.cancel(); channel.close(promise: nil) }
        return try await done.futureResult.get()
    }

    /// A port nothing listens on right now (bound and released).
    static func freePort() async throws -> Int {
        let probe = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = probe.localAddress!.port!
        try await probe.close()
        return port
    }

    final class Collector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private var received = ByteBuffer()
        private let expect: Int
        private let done: EventLoopPromise<String>

        init(expect: Int, done: EventLoopPromise<String>) {
            self.expect = expect
            self.done = done
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            received.writeBuffer(&bytes)
            if received.readableBytes >= expect { finish() }
        }

        func channelInactive(context: ChannelHandlerContext) { finish() }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            finish()
            context.close(promise: nil)
        }

        private var finished = false
        private func finish() {
            guard !finished else { return }
            finished = true
            done.succeed(String(buffer: received))
        }
    }
}
