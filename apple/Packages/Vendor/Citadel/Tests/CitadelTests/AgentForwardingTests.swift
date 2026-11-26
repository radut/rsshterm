// rSSH patch (see PATCHES.md): agent channel routing and the decrypted private section of OpenSSH keys.
@testable import Citadel
import Crypto
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
@preconcurrency import NIOSSH
import XCTest

final class AgentForwardingTests: XCTestCase {
    // ssh-keygen -t ed25519, passphrase "example" (the fixture of KeyTests.testEncryptedED25519PrivateKey).
    private let encryptedKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBQRAFCo9
    /vv0icX60s6O6UAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIBrez0rdYqROdkIA
    qvSrLoYFO1KVEidE4wclxivVKMbmAAAAoA9dkA6h2tAtANBP9RzyKvgrw5JKVJLVHfvZRQ
    8d3ttvy7WOs15y8lL/SdHiCyRukkKOPRd02zqx5g6WSmXZ0dKho/aMMO+58cIxsbCmMePT
    HaJvuQjIx6DIEoQyq83rQeVngk5rgvgou2jgHy/35C1AHtUysH4DIcltmrU3rvMF8i2GL4
    Od3cZL5cIOQVsmAZS6t3oL+GVeVOMFCqGFxjc=
    -----END OPENSSH PRIVATE KEY-----
    """

    // MARK: Decrypted private section

    func testEncryptedSectionDecryptsToTheKeyCitadelReads() throws {
        let section = try OpenSSHPrivateSection.decrypted(encryptedKey, passphrase: Data("example".utf8))
        var buffer = ByteBuffer(data: section)
        let check0 = buffer.readInteger(as: UInt32.self), check1 = buffer.readInteger(as: UInt32.self)
        XCTAssertEqual(check0, check1)
        XCTAssertEqual(buffer.readSSHString(), "ssh-ed25519")
        let publicKey = try XCTUnwrap(buffer.readSSHBuffer())
        var secret = try XCTUnwrap(buffer.readSSHBuffer())
        let seed = try XCTUnwrap(secret.readBytes(length: 32))

        let citadelKey = try Curve25519.Signing.PrivateKey(sshEd25519: encryptedKey, decryptionKey: Data("example".utf8))
        XCTAssertEqual(Data(seed), citadelKey.rawRepresentation)
        XCTAssertEqual(Data(publicKey.readableBytesView), citadelKey.publicKey.rawRepresentation)
    }

    func testWrongPassphraseThrows() {
        XCTAssertThrowsError(try OpenSSHPrivateSection.decrypted(encryptedKey, passphrase: Data("wrong".utf8)))
    }

    func testMissingPassphraseThrows() {
        XCTAssertThrowsError(try OpenSSHPrivateSection.decrypted(encryptedKey, passphrase: nil))
    }

    func testUnencryptedKeyReturnsItsSection() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pem = key.makeSSHRepresentation(comment: "phone")
        let section = try OpenSSHPrivateSection.decrypted(pem, passphrase: nil)
        var buffer = ByteBuffer(data: section)
        buffer.moveReaderIndex(forwardBy: 8)
        XCTAssertEqual(buffer.readSSHString(), "ssh-ed25519")
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try OpenSSHPrivateSection.decrypted("not a key", passphrase: nil))
        XCTAssertThrowsError(try OpenSSHPrivateSection.decrypted(
            "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----", passphrase: nil))
    }

    // MARK: Channel routing

    func testAgentChannelIsRefusedWithoutHandler() throws {
        let inbound = SSHClientInboundChannelHandler()
        let channel = EmbeddedChannel()
        XCTAssertThrowsError(try inbound.handleChannel(channel: channel, channelType: .authAgent).wait())
    }

    func testAgentChannelGoesToTheHandlerWithByteBuffers() throws {
        let inbound = SSHClientInboundChannelHandler()
        let calls = NIOLockedValueBox(0)
        inbound.agentHandler.withLockedValue { $0 = { channel in
            calls.withLockedValue { $0 += 1 }
            return channel.pipeline.addHandler(EchoHandler())
        } }
        let channel = EmbeddedChannel()
        try inbound.handleChannel(channel: channel, channelType: .authAgent).wait()
        XCTAssertEqual(calls.withLockedValue { $0 }, 1)

        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: [0, 0, 0, 1, 11]))))
        let reply = try XCTUnwrap(try channel.readOutbound(as: SSHChannelData.self))
        guard case .byteBuffer(let bytes) = reply.data else { return XCTFail("not bytes") }
        XCTAssertEqual(Array(bytes.readableBytesView), [0, 0, 0, 1, 11])
    }

    func testSessionChannelsAreStillRefused() {
        let inbound = SSHClientInboundChannelHandler()
        inbound.agentHandler.withLockedValue { $0 = { $0.eventLoop.makeSucceededVoidFuture() } }
        XCTAssertThrowsError(try inbound.handleChannel(channel: EmbeddedChannel(), channelType: .session).wait())
    }
}

private final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}
