import Foundation
import Testing
@testable import RSSHTunnel

/// The FreeRDP spike (spikes/freerdp-grab, docs/research/remote-desktop.md): libfreerdp3 logs in to xrdp through
/// the SSH tunnel and gets a frame. Runs with `RDP=1 test/integration.sh`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RSSH_RD_IT_RDP_GRAB"] != nil,
                "needs RDP=1 test/integration.sh"))
struct RDPSpikeIntegrationTests {
    @Test func freeRDPGetsAFrameThroughTheTunnel() async throws {
        let env = ProcessInfo.processInfo.environment
        let rdp = try #require(IntegrationEnvironment.target("RDP"))
        let client = try await IntegrationEnvironment.connect()
        let forwarder = try await LocalPortForwarder.start(opener: CitadelForwardOpener(client: client),
                                                           targetHost: rdp.host, targetPort: rdp.port, acceptLimit: 1)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-\(UUID().uuidString).ppm")
        defer { try? FileManager.default.removeItem(at: out) }

        let grab = Process()
        grab.executableURL = URL(fileURLWithPath: try #require(env["RSSH_RD_IT_RDP_GRAB"]))
        grab.arguments = ["127.0.0.1", String(forwarder.localPort), try #require(env["RSSH_RD_IT_RDP_USER"]), out.path]
        // The password goes in the environment, never on a command line other processes can read.
        // FreeRDP keeps its config under $HOME (winpr refuses a context without one): a scratch home.
        grab.environment = ["RDP_PASSWORD": try #require(env["RSSH_RD_IT_RDP_PASSWORD"]),
                            "HOME": FileManager.default.temporaryDirectory.path]
        let pipe = Pipe()
        grab.standardOutput = pipe
        grab.standardError = pipe
        try grab.run()
        let output = String(decoding: try pipe.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        grab.waitUntilExit()

        #expect(grab.terminationStatus == 0, "grab said: \(output)")
        #expect(output.contains("colours=many"))
        let header = try String(decoding: Data(contentsOf: out).prefix(16), as: UTF8.self)
        #expect(header.hasPrefix("P6\n1024 768\n"))
        await forwarder.close()
        try await client.close()
    }
}
