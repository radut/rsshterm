//===----------------------------------------------------------------------===//
//
// rSSH patch (see PATCHES.md): agent forwarding, "auth-agent-req@openssh.com" on a session channel and the
// server-initiated "auth-agent@openssh.com" channel. Licensed under Apache License v2.0 like the rest of the package.
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
@testable import NIOSSH
import XCTest

final class AgentForwardingTests: XCTestCase {
    // MARK: Wire format

    func testAgentChannelOpenRoundTrips() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        let message = SSHMessage.channelOpen(.init(type: .authAgent, senderChannel: 7, initialWindowSize: 2_097_152, maximumPacketSize: 32768))
        buffer.writeSSHMessage(message)
        XCTAssertEqual(try buffer.readSSHMessage(), message)
    }

    func testAgentChannelOpenBytesMatchOpenSSH() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        buffer.writeSSHMessage(.channelOpen(.init(type: .authAgent, senderChannel: 1, initialWindowSize: 2, maximumPacketSize: 3)))

        var expected = ByteBufferAllocator().buffer(capacity: 100)
        expected.writeInteger(UInt8(90))
        expected.writeSSHString("auth-agent@openssh.com".utf8)
        expected.writeInteger(UInt32(1))
        expected.writeInteger(UInt32(2))
        expected.writeInteger(UInt32(3))
        XCTAssertEqual(buffer, expected)
    }

    func testAgentChannelOpenFromOpenSSHBytesParses() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        buffer.writeInteger(UInt8(90))
        buffer.writeSSHString("auth-agent@openssh.com".utf8)
        buffer.writeInteger(UInt32(4))
        buffer.writeInteger(UInt32(65536))
        buffer.writeInteger(UInt32(16384))
        XCTAssertEqual(try buffer.readSSHMessage(),
                       .channelOpen(.init(type: .authAgent, senderChannel: 4, initialWindowSize: 65536, maximumPacketSize: 16384)))
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testAgentChannelOpenPartialReadsReturnNil() throws {
        var full = ByteBufferAllocator().buffer(capacity: 100)
        let message = SSHMessage.channelOpen(.init(type: .authAgent, senderChannel: 0, initialWindowSize: 42, maximumPacketSize: 24))
        full.writeSSHMessage(message)
        let bytes = Array(full.readableBytesView)

        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        for byte in bytes.dropLast() {
            buffer.writeInteger(byte)
            XCTAssertNil(try buffer.readSSHMessage())
        }
        buffer.writeInteger(bytes.last!)
        XCTAssertEqual(try buffer.readSSHMessage(), message)
    }

    func testAgentRequestRoundTrips() throws {
        for wantReply in [false, true] {
            var buffer = ByteBufferAllocator().buffer(capacity: 100)
            let message = SSHMessage.channelRequest(.init(recipientChannel: 3, type: .authAgentRequest, wantReply: wantReply))
            buffer.writeSSHMessage(message)
            XCTAssertEqual(try buffer.readSSHMessage(), message)
        }
    }

    func testAgentRequestBytesMatchOpenSSH() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        buffer.writeSSHMessage(.channelRequest(.init(recipientChannel: 9, type: .authAgentRequest, wantReply: false)))

        var expected = ByteBufferAllocator().buffer(capacity: 100)
        expected.writeInteger(UInt8(98))
        expected.writeInteger(UInt32(9))
        expected.writeSSHString("auth-agent-req@openssh.com".utf8)
        expected.writeInteger(UInt8(0))
        XCTAssertEqual(buffer, expected)
    }

    func testAgentRequestEventConvertsBothWays() {
        let message = SSHMessage.ChannelRequestMessage(recipientChannel: 1, type: .authAgentRequest, wantReply: false)
        XCTAssertEqual(SSHChannelRequestEvent.fromMessage(message) as? SSHChannelRequestEvent.AgentForwardingRequest,
                       SSHChannelRequestEvent.AgentForwardingRequest(wantReply: false))
        XCTAssertEqual(SSHMessage(SSHChannelRequestEvent.AgentForwardingRequest(), recipientChannel: 1), .channelRequest(message))
    }

    func testChannelTypeMapsToMessageTypeAndBack() {
        XCTAssertEqual(SSHMessage.ChannelOpenMessage.ChannelType(SSHChannelType.authAgent), .authAgent)
        let open = SSHMessage.ChannelOpenMessage(type: .authAgent, senderChannel: 0, initialWindowSize: 1, maximumPacketSize: 1)
        XCTAssertEqual(SSHChannelType(open), .authAgent)
    }

    func testOtherUnknownChannelTypesAreStillRejected() {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        buffer.writeInteger(UInt8(90))
        buffer.writeSSHString("x11".utf8)
        buffer.writeInteger(UInt32(0))
        buffer.writeInteger(UInt32(1))
        buffer.writeInteger(UInt32(1))
        XCTAssertThrowsError(try buffer.readSSHMessage()) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .unknownPacketType)
        }
    }

    // MARK: End to end

    /// The server opens an agent channel to a client that accepts it; bytes flow both ways.
    func testServerOpensAgentChannelToClient() throws {
        let pair = AgentPair()
        try pair.start()
        defer { pair.finish() }

        var serverSide: Channel?
        pair.serverHandler.createChannel(nil, channelType: .authAgent) { channel, type in
            XCTAssertEqual(type, .authAgent)
            serverSide = channel
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        try pair.interact()

        XCTAssertEqual(pair.clientChannels.map(\.type), [.authAgent])
        let clientSide = try XCTUnwrap(pair.clientChannels.first?.channel)
        let serverChannel = try XCTUnwrap(serverSide)
        XCTAssertEqual(try clientSide.getOption(SSHChildChannelOptions.sshChannelType).wait(), SSHChannelType.authAgent)

        let recorder = DataRecorder()
        try clientSide.pipeline.addHandler(recorder).wait()
        let request = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: [0, 0, 0, 1, 11])))
        serverChannel.writeAndFlush(request, promise: nil)
        try pair.interact()
        XCTAssertEqual(recorder.received, [[0, 0, 0, 1, 11]])
    }

    /// A client whose initializer fails (no agent offered) refuses the channel; the connection survives.
    func testClientRefusingAgentChannelKeepsConnection() throws {
        let pair = AgentPair(acceptInbound: false)
        try pair.start()
        defer { pair.finish() }

        let promise = pair.loop.makePromise(of: Channel.self)
        pair.serverHandler.createChannel(promise, channelType: .authAgent) { channel, _ in
            channel.eventLoop.makeSucceededVoidFuture()
        }
        var failed = false
        promise.futureResult.whenFailure { _ in failed = true }
        try pair.interact()
        XCTAssertTrue(failed)
        XCTAssertTrue(pair.client.isActive)
    }
}

private final class DataRecorder: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    var received: [[UInt8]] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let buffer) = self.unwrapInboundIn(data).data else { return }
        self.received.append(Array(buffer.readableBytesView))
    }
}

/// A client and a server over embedded channels, where the client records the channels the server opens.
private final class AgentPair {
    let loop = EmbeddedEventLoop()
    let client: EmbeddedChannel
    let server: EmbeddedChannel
    let acceptInbound: Bool
    var clientChannels: [(channel: Channel, type: SSHChannelType)] = []

    init(acceptInbound: Bool = true) {
        self.client = EmbeddedChannel(loop: self.loop)
        self.server = EmbeddedChannel(loop: self.loop)
        self.acceptInbound = acceptInbound
    }

    var serverHandler: NIOSSHHandler {
        try! self.server.pipeline.handler(type: NIOSSHHandler.self).wait()
    }

    func start() throws {
        let harness = TestHarness()
        let clientConfiguration = SSHClientConfiguration(userAuthDelegate: harness.clientAuthDelegate,
                                                         serverAuthDelegate: harness.clientServerAuthDelegate)
        let serverConfiguration = SSHServerConfiguration(hostKeys: harness.serverHostKeys,
                                                         userAuthDelegate: harness.serverAuthDelegate)
        let accept = self.acceptInbound
        let initializer: (Channel, SSHChannelType) -> EventLoopFuture<Void> = { channel, type in
            guard accept else { return channel.eventLoop.makeFailedFuture(ChannelError.operationUnsupported) }
            self.clientChannels.append((channel, type))
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        let clientHandler = NIOSSHHandler(role: .client(clientConfiguration), allocator: self.client.allocator,
                                          inboundChildChannelInitializer: initializer)
        let serverHandler = NIOSSHHandler(role: .server(serverConfiguration), allocator: self.server.allocator,
                                          inboundChildChannelInitializer: nil)
        try self.client.pipeline.addHandler(clientHandler).wait()
        try self.server.pipeline.addHandler(serverHandler).wait()
        try self.client.connect(to: .init(unixDomainSocketPath: "/fake")).wait()
        try self.server.connect(to: .init(unixDomainSocketPath: "/fake")).wait()
        try self.interact()
    }

    func interact() throws {
        var workToDo = true
        while workToDo {
            workToDo = false
            self.loop.run()
            if let datum = try self.client.readOutbound(as: IOData.self) {
                try self.server.writeInbound(datum)
                workToDo = true
            }
            if let datum = try self.server.readOutbound(as: IOData.self) {
                try self.client.writeInbound(datum)
                workToDo = true
            }
        }
    }

    func finish() {
        _ = try? self.client.finish(acceptAlreadyClosed: true)
        _ = try? self.server.finish(acceptAlreadyClosed: true)
        try? self.loop.syncShutdownGracefully()
    }
}
