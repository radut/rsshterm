import Citadel
import Foundation
import Testing
@testable import RSSHTunnel

/// The forwarder over a real OpenSSH server (test/integration.sh): direct-tcpip channels to a TigerVNC server
/// that only the SSH server can reach.
@Suite(.enabled(if: IntegrationEnvironment.enabled, "needs the docker rig: test/integration.sh"), .serialized)
struct SSHTunnelIntegrationTests {
    @Test func theVNCBannerArrivesThroughTheTunnel() async throws {
        let vnc = try #require(IntegrationEnvironment.target("VNC"))
        let client = try await IntegrationEnvironment.connect()
        let forwarder = try await LocalPortForwarder.start(opener: CitadelForwardOpener(client: client),
                                                           targetHost: vnc.host, targetPort: vnc.port)
        let banner = try await TCPProbe.exchange(port: forwarder.localPort, send: "", expect: 12)
        #expect(banner == "RFB 003.008\n")
        // The banner can come through before the forward's completion is recorded: give it a moment.
        var opened = false
        for _ in 0..<50 where !opened {
            opened = await forwarder.recentEvents().contains(.forwardOpened)
            if !opened { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(opened)
        await forwarder.close()
        try await client.close()
    }

    @Test func manyConnectionsShareOneSSHConnection() async throws {
        let vnc = try #require(IntegrationEnvironment.target("VNC"))
        let client = try await IntegrationEnvironment.connect()
        let forwarder = try await LocalPortForwarder.start(opener: CitadelForwardOpener(client: client),
                                                           targetHost: vnc.host, targetPort: vnc.port)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<4 {
                group.addTask { try await TCPProbe.exchange(port: forwarder.localPort, send: "", expect: 12) }
            }
            for try await banner in group { #expect(banner == "RFB 003.008\n") }
        }
        await forwarder.close()
        try await client.close()
    }

    @Test func aTargetTheServerCannotReachClosesTheLocalConnection() async throws {
        let vnc = try #require(IntegrationEnvironment.target("VNC"))
        let client = try await IntegrationEnvironment.connect()
        // Nothing listens on port 1 of the VNC container: sshd answers "connect failed".
        let forwarder = try await LocalPortForwarder.start(opener: CitadelForwardOpener(client: client),
                                                           targetHost: vnc.host, targetPort: 1)
        let reply = try await TCPProbe.exchange(port: forwarder.localPort, send: "x", expect: 1)
        #expect(reply.isEmpty)
        let failed = await forwarder.recentEvents().contains { if case .forwardFailed = $0 { true } else { false } }
        #expect(failed)
        await forwarder.close()
        try await client.close()
    }
}
