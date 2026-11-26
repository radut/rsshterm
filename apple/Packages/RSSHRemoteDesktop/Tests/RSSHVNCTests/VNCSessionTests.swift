import Foundation
import NIOCore
import NIOPosix
import RoyalVNCKit
import RSSHKit
import Testing
@testable import RSSHVNC

@Suite struct VNCCredentialTests {
    @Test func vncPasswordNeedsOnlyThePassword() throws {
        let c = try #require(VNCCredentials.credential(for: .vncPassword, login: VNCLogin(username: nil, password: "pw"))
            as? VNCPasswordCredential)
        #expect(c.password == "pw")
    }

    @Test func macAndWindowsAccountsNeedAUser() throws {
        let c = try #require(VNCCredentials.credential(for: .macAccount, login: VNCLogin(username: "me", password: "pw"))
            as? VNCUsernamePasswordCredential)
        #expect(c.username == "me" && c.password == "pw")
        #expect(VNCCredentials.credential(for: .macAccount, login: VNCLogin(username: nil, password: "pw")) == nil)
        #expect(VNCCredentials.credential(for: .windowsAccount, login: VNCLogin(username: "", password: "pw")) == nil)
    }

    @Test func noLoginOrAnEmptyPasswordAnswersNothing() {
        #expect(VNCCredentials.credential(for: .vncPassword, login: nil) == nil)
        #expect(VNCCredentials.credential(for: .vncPassword, login: VNCLogin(username: nil, password: "")) == nil)
    }

    @Test func loginComesFromTheVault() throws {
        let pw = Credential(label: "mac", kind: .password("s3cret"))
        let mac = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "me",
                                credentialID: pw.id)
        let vault = Vault(credentials: [pw], remoteDesktops: [mac])
        #expect(mac.vncLogin(in: vault) == VNCLogin(username: "me", password: "s3cret"))
        // A VNC entry never sends a user, even one left over from an edit.
        var vnc = mac
        vnc.kind = .vnc
        #expect(vnc.vncLogin(in: vault) == VNCLogin(username: nil, password: "s3cret"))
        #expect(RemoteDesktop(name: "x", kind: .vnc, host: "h").vncLogin(in: vault) == nil)
    }
}

/// RFBProbe against a fake server on this machine (the real servers are in the docker integration tests).
@Suite struct RFBProbeTests {
    @Test func readsAppleStyleHello() async throws {
        let server = try await FakeRFBServer.start(greeting: "RFB 003.889\n", security: [4, 30, 33, 36, 35])
        let hello = try await RFBProbe.hello(host: "127.0.0.1", port: server.port)
        #expect(hello.isApple)
        #expect(hello.securityTypes == [.appleDiffieHellman, .apple33, .apple36, .apple35])
        #expect(await server.clientVersion() == "RFB 003.008\n")
        await server.close()
    }

    @Test func notAVNCServer() async throws {
        let server = try await FakeRFBServer.start(greeting: "SSH-2.0-OpenSSH_9.6\r\n", security: [])
        await #expect(throws: RFBHandshakeError.self) { try await RFBProbe.hello(host: "127.0.0.1", port: server.port) }
        await server.close()
    }

    @Test func aSilentServerTimesOut() async throws {
        let server = try await FakeRFBServer.start(greeting: "", security: [])
        await #expect(throws: RFBProbe.Timeout.self) {
            try await RFBProbe.hello(host: "127.0.0.1", port: server.port, timeout: .milliseconds(300))
        }
        await server.close()
    }
}

/// Sends a greeting, records the client's 12-byte version, then sends the security bytes.
struct FakeRFBServer {
    let channel: any Channel
    let recorder: Recorder
    var port: Int { channel.localAddress!.port! }

    actor Recorder {
        var version = ""
        func set(_ v: String) { version = v }
    }

    func clientVersion() async -> String {
        for _ in 0..<50 where await recorder.version.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        return await recorder.version
    }

    static func start(greeting: String, security: [UInt8]) async throws -> FakeRFBServer {
        let recorder = Recorder()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { $0.pipeline.addHandler(Handler(greeting: greeting, security: security,
                                                                      recorder: recorder)) }
            .bind(host: "127.0.0.1", port: 0).get()
        return FakeRFBServer(channel: channel, recorder: recorder)
    }

    func close() async { try? await channel.close() }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let greeting: String, security: [UInt8], recorder: Recorder
        var got: [UInt8] = []

        init(greeting: String, security: [UInt8], recorder: Recorder) {
            self.greeting = greeting
            self.security = security
            self.recorder = recorder
        }

        func channelActive(context: ChannelHandlerContext) {
            if !greeting.isEmpty { context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: greeting)), promise: nil) }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            got += unwrapInboundIn(data).readableBytesView
            guard got.count >= 12 else { return }
            let version = String(decoding: got.prefix(12), as: UTF8.self)
            got.removeAll()
            Task { await recorder.set(version) }
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: security)), promise: nil)
        }
    }
}
