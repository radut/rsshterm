import Citadel
import Crypto
import Foundation
import RSSHTunnel
import Testing
@testable import RSSHVNC

/// RoyalVNCKit through the SSH tunnel to TigerVNC (test/integration.sh): the path the app takes.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RSSH_RD_IT_SSH_HOST"] != nil,
                "needs the docker rig: test/integration.sh"), .serialized)
struct VNCIntegrationTests {
    let env = ProcessInfo.processInfo.environment

    func tunnel() async throws -> (SSHClient, LocalPortForwarder) {
        let pem = try String(contentsOfFile: try #require(env["RSSH_RD_IT_SSH_KEY"]), encoding: .utf8)
        let client = try await SSHClient.connect(
            host: try #require(env["RSSH_RD_IT_SSH_HOST"]), port: Int(env["RSSH_RD_IT_SSH_PORT"] ?? "22") ?? 22,
            authenticationMethod: .ed25519(username: try #require(env["RSSH_RD_IT_SSH_USER"]),
                                           privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: pem)),
            hostKeyValidator: .acceptAnything(), reconnect: .never)
        let forwarder = try await LocalPortForwarder.start(
            opener: CitadelForwardOpener(client: client), targetHost: try #require(env["RSSH_RD_IT_VNC_HOST"]),
            targetPort: Int(try #require(env["RSSH_RD_IT_VNC_PORT"])) ?? 5900)
        return (client, forwarder)
    }

    /// Collects events until `stop` says so or `seconds` pass; on a timeout, returns what arrived until then.
    func collect(_ session: VNCSession, seconds: Double = 20,
                 until stop: @escaping @Sendable ([VNCSessionEvent]) -> Bool) async -> [VNCSessionEvent] {
        let seen = Seen()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in session.events {
                    if stop(await seen.append(event)) { return }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
            session.disconnect()
        }
        return await seen.events
    }

    actor Seen {
        var events: [VNCSessionEvent] = []
        func append(_ e: VNCSessionEvent) -> [VNCSessionEvent] { events.append(e); return events }
    }

    @Test func probeShowsTheVNCPasswordType() async throws {
        let (client, forwarder) = try await tunnel()
        let hello = try await RFBProbe.hello(host: "127.0.0.1", port: forwarder.localPort)
        #expect(hello.major == 3 && hello.minor == 8)
        #expect(hello.securityTypes == [.vncPassword])
        #expect(VNCAuthPlan.plan(for: hello, preferAccount: false) == .inApp(.vncPassword))
        await forwarder.close()
        try await client.close()
    }

    @Test func royalVNCKitOpensTheScreenAndGetsFrames() async throws {
        let (client, forwarder) = try await tunnel()
        let session = VNCSession(port: forwarder.localPort,
                                 login: VNCLogin(username: nil, password: try #require(env["RSSH_RD_IT_VNC_PASSWORD"])),
                                 options: { var o = VNCSession.Options(); o.clipboard = false; return o }())
        session.connect()
        // A frame (an empty update only says the cursor changed).
        let painted: @Sendable (VNCSessionEvent) -> Bool = { if case .updated(_, _, let w, _) = $0 { w > 0 } else { false } }
        let events = await collect(session) { seen in seen.contains(where: painted) }
        #expect(events.contains(.connected(width: 800, height: 600)))
        #expect(events.contains(where: painted))
        let fb = try #require(session.framebuffer)
        #expect(fb.size.width == 800 && fb.size.height == 600)
        // The xterm drew something: not every pixel is the same.
        let pixels = UnsafeBufferPointer(start: fb.surfaceAddress.assumingMemoryBound(to: UInt32.self),
                                         count: fb.surfaceByteCount / 4)
        #expect(Set(pixels.prefix(800 * 300)).count > 1)
        await forwarder.close()
        try await client.close()
    }

    @Test func theServersClipboardArrivesWithoutPasteboardSync() async throws {
        let (client, forwarder) = try await tunnel()
        let session = VNCSession(port: forwarder.localPort,
                                 login: VNCLogin(username: nil, password: try #require(env["RSSH_RD_IT_VNC_PASSWORD"])),
                                 options: { var o = VNCSession.Options(); o.clipboard = false; return o }())
        session.connect()
        let events = await collect(session, seconds: 25) { seen in
            seen.contains { if case .remoteClipboard = $0 { true } else { false } }
        }
        #expect(events.contains(.remoteClipboard("rSshTerm VNC clipboard")),
                "events: \(events.filter { if case .updated = $0 { false } else { true } })")
        await forwarder.close()
        try await client.close()
    }

    @Test func aWrongPasswordDisconnectsWithAReason() async throws {
        let (client, forwarder) = try await tunnel()
        let session = VNCSession(port: forwarder.localPort, login: VNCLogin(username: nil, password: "wrong-pw"),
                                 options: { var o = VNCSession.Options(); o.clipboard = false; return o }())
        session.connect()
        let events = await collect(session) { seen in
            seen.contains { if case .disconnected = $0 { true } else { false } }
        }
        let reason = events.compactMap { if case .authenticationFailed(let r) = $0 { r } else { nil } }.first
        #expect(reason != nil)
        #expect(!events.contains { if case .connected = $0 { true } else { false } })
        await forwarder.close()
        try await client.close()
    }

    @Test func noStoredLoginAsksForOne() async throws {
        let (client, forwarder) = try await tunnel()
        let session = VNCSession(port: forwarder.localPort, login: nil,
                                 options: { var o = VNCSession.Options(); o.clipboard = false; return o }())
        session.connect()
        let events = await collect(session) { seen in
            seen.contains { if case .disconnected = $0 { true } else { false } }
        }
        #expect(events.contains(.needsLogin(accountType: .vncPassword)))
        await forwarder.close()
        try await client.close()
    }
}
