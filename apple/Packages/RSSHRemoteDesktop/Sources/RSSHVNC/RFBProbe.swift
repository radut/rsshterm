import Foundation
import NIOCore
import NIOPosix

/// Connects, reads the server's version and security types, and hangs up before any authentication. Shows the
/// user what a Mac offers (ARD type 30 or only Apple's newer types) before a password is typed.
public enum RFBProbe {
    public struct Timeout: Error, LocalizedError {
        public var errorDescription: String? { "The VNC server did not answer in time." }
    }

    public static func hello(host: String, port: Int, timeout: TimeAmount = .seconds(10),
                             group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton)
        async throws -> RFBServerHello {
        let loop = group.next()
        let done = loop.makePromise(of: RFBServerHello.self)
        let timer = loop.scheduleTask(in: timeout) { done.fail(Timeout()) }
        defer { timer.cancel() }
        let channel: any Channel
        do {
            channel = try await ClientBootstrap(group: loop)
                .connectTimeout(timeout)
                .channelInitializer { $0.pipeline.addHandler(Reader(done: done)) }
                .connect(host: host, port: port).get()
        } catch {
            // Settle the promise: NIO traps on a promise that is dropped unfulfilled.
            done.fail(error)
            throw error
        }
        defer { channel.close(promise: nil) }
        return try await done.futureResult.get()
    }

    final class Reader: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        private var bytes: [UInt8] = []
        private var version: (major: Int, minor: Int)?
        private let done: EventLoopPromise<RFBServerHello>
        private var finished = false

        init(done: EventLoopPromise<RFBServerHello>) { self.done = done }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            bytes += buffer.readableBytesView
            // A handshake is a few dozen bytes; anything past 8 KiB is not one.
            guard bytes.count < 8192 else { return finish(.failure(RFBHandshakeError.truncated), context) }
            do {
                if version == nil {
                    guard bytes.count >= RFBHandshake.versionLength else { return }
                    let v = try RFBHandshake.parseVersion(bytes)
                    version = v
                    bytes.removeFirst(RFBHandshake.versionLength)
                    context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: RFBHandshake.clientVersion(
                        major: v.major, minor: v.minor))), promise: nil)
                }
                if let v = version, let security = RFBHandshake.parseSecurity(bytes, major: v.major, minor: v.minor) {
                    finish(.success(RFBServerHello(major: v.major, minor: v.minor, securityTypes: security.types,
                                                   failureReason: security.reason)), context)
                }
            } catch {
                finish(.failure(error), context)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            finish(.failure(RFBHandshakeError.truncated), context)
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            finish(.failure(error), context)
        }

        private func finish(_ result: Result<RFBServerHello, any Error>, _ context: ChannelHandlerContext) {
            guard !finished else { return }
            finished = true
            done.completeWith(result)
            context.close(promise: nil)
        }
    }
}
