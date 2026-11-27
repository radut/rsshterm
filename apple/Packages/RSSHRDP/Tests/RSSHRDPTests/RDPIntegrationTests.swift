import Citadel
import Crypto
import Foundation
import RSSHKit
import RSSHTunnel
import Testing
@testable import RSSHRDP

/// RDPSession through the SSH tunnel to xrdp (RDP=1 apple/Packages/RSSHRemoteDesktop/test/integration.sh).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RSSH_RD_IT_RDP_HOST"] != nil,
                "needs RDP=1 test/integration.sh"), .serialized)
struct RDPIntegrationTests {
    let env = ProcessInfo.processInfo.environment

    func tunnel() async throws -> (SSHClient, LocalPortForwarder) {
        let pem = try String(contentsOfFile: try #require(env["RSSH_RD_IT_SSH_KEY"]), encoding: .utf8)
        let client = try await SSHClient.connect(
            host: try #require(env["RSSH_RD_IT_SSH_HOST"]), port: Int(env["RSSH_RD_IT_SSH_PORT"] ?? "22") ?? 22,
            authenticationMethod: .ed25519(username: try #require(env["RSSH_RD_IT_SSH_USER"]),
                                           privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: pem)),
            hostKeyValidator: .acceptAnything(), reconnect: .never)
        let forwarder = try await LocalPortForwarder.start(
            opener: CitadelForwardOpener(client: client), targetHost: try #require(env["RSSH_RD_IT_RDP_HOST"]),
            targetPort: Int(env["RSSH_RD_IT_RDP_PORT"] ?? "3389") ?? 3389, acceptLimit: 1)
        return (client, forwarder)
    }

    var login: RemoteDesktopLogin {
        RemoteDesktopLogin(username: env["RSSH_RD_IT_RDP_USER"], password: env["RSSH_RD_IT_RDP_PASSWORD"] ?? "")
    }

    /// Events until `stop` or `seconds`; on a timeout, what arrived until then.
    func collect(_ session: RDPSession, seconds: Double = 25,
                 until stop: @escaping @Sendable ([RDPSessionEvent]) -> Bool) async -> [RDPSessionEvent] {
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
        }
        return await seen.events
    }

    actor Seen {
        var events: [RDPSessionEvent] = []
        func append(_ e: RDPSessionEvent) -> [RDPSessionEvent] { events.append(e); return events }
    }

    static func painted(_ seen: [RDPSessionEvent]) -> Bool {
        seen.contains { if case .connected = $0 { true } else { false } }
            && seen.contains { if case .updated = $0 { true } else { false } }
    }

    /// The certificate xrdp presents (TOFU step one): reported and refused.
    func firstFingerprint() async throws -> String {
        let (client, forwarder) = try await tunnel()
        let session = RDPSession(port: forwarder.localPort, login: login, pinnedCertificate: nil)
        session.connect()
        let events = await collect(session) { $0.contains { if case .disconnected = $0 { true } else { false } } }
        await forwarder.close()
        try await client.close()
        let fp = events.compactMap { e -> String? in
            if case .certificateNeedsTrust(let fp, _, .askToTrust) = e { fp } else { nil }
        }.first
        return try #require(fp, "events: \(events)")
    }

    @Test func unpinnedCertificateIsReportedAndRefusedThenThePinConnects() async throws {
        let fingerprint = try await firstFingerprint()
        #expect(!fingerprint.isEmpty)

        let (client, forwarder) = try await tunnel()
        let session = RDPSession(port: forwarder.localPort, login: login, pinnedCertificate: fingerprint,
                                 options: { var o = RDPSession.Options(); o.width = 1024; o.height = 768; return o }())
        session.connect()
        let events = await collect(session) { Self.painted($0) }
        try await Task.sleep(for: .seconds(2))   // let the session draw its window
        #expect(events.contains(.connected(width: 1024, height: 768)),
                "events: \(events.filter { if case .updated = $0 { false } else { true } })")
        let varied = session.withFramebuffer { buffer, width, height, rowBytes -> Bool in
            guard let buffer, width > 0 else { return false }
            let first = buffer.load(fromByteOffset: 0, as: UInt32.self)
            for y in stride(from: 0, to: height, by: 7) {
                for x in stride(from: 0, to: width, by: 13) where buffer.load(fromByteOffset: y * rowBytes + x * 4, as: UInt32.self) != first {
                    return true
                }
            }
            return false
        }
        #expect(varied)
        session.disconnect()
        await forwarder.close()
        try await client.close()
    }

    @Test func freeRDPKeepsNoCertificateStoreOfItsOwn() throws {
        // Every certificate is accepted for one session only (2): the vault pin is the only store.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let store = home.appendingPathComponent(".config/freerdp")
        let files = (FileManager.default.enumerator(atPath: store.path)?.allObjects as? [String]) ?? []
        #expect(files.filter { $0.contains("known_hosts") || $0.hasSuffix(".pem") }.isEmpty, "found \(files)")
    }

    @Test func aChangedCertificateIsRefused() async throws {
        let (client, forwarder) = try await tunnel()
        let session = RDPSession(port: forwarder.localPort, login: login, pinnedCertificate: "00:11:22")
        session.connect()
        let events = await collect(session) { $0.contains { if case .disconnected = $0 { true } else { false } } }
        #expect(events.contains { if case .certificateNeedsTrust(_, _, .changed(expected: "00:11:22")) = $0 { true } else { false } })
        #expect(!events.contains { if case .connected = $0 { true } else { false } })
        await forwarder.close()
        try await client.close()
    }

    @Test func clipboardTextArrivesFromTheServer() async throws {
        let fingerprint = try await firstFingerprint()
        let (client, forwarder) = try await tunnel()
        var options = RDPSession.Options()
        options.clipboard = true
        let session = RDPSession(port: forwarder.localPort, login: login, pinnedCertificate: fingerprint, options: options)
        session.connect()
        session.setLocalClipboard("from the device")
        let events = await collect(session, seconds: 30) { seen in
            seen.contains { if case .remoteClipboard = $0 { true } else { false } }
        }
        #expect(events.contains(.remoteClipboard("rSshTerm clipboard test")), "events: \(events.filter { if case .updated = $0 { false } else { true } })")
        session.disconnect()
        await forwarder.close()
        try await client.close()
    }

    @Test func typingChangesTheScreen() async throws {
        let fingerprint = try await firstFingerprint()
        let (client, forwarder) = try await tunnel()
        let session = RDPSession(port: forwarder.localPort, login: login, pinnedCertificate: fingerprint)
        session.connect()
        _ = await collect(session) { Self.painted($0) }
        try await Task.sleep(for: .seconds(2))
        let before = session.withFramebuffer { buffer, _, _, _ in buffer.map { Data($0) } }
        session.type("echo typed-through-rdp\n")
        _ = await collect(session, seconds: 5) { $0.contains { if case .updated = $0 { true } else { false } } }
        try await Task.sleep(for: .seconds(1))
        let after = session.withFramebuffer { buffer, _, _, _ in buffer.map { Data($0) } }
        #expect(before != nil && after != nil && before != after)
        session.disconnect()
        await forwarder.close()
        try await client.close()
    }
}
