import Foundation
import Testing
@testable import RSSHVNC

@Suite struct RFBProbeCommandTests {
    @Test func parsesArguments() throws {
        #expect(try RFBProbeCommand.Options.parse(["mac.example.net"]) == .init(host: "mac.example.net", port: 5900, json: false))
        #expect(try RFBProbeCommand.Options.parse(["127.0.0.1", "5901", "--json"]) == .init(host: "127.0.0.1", port: 5901, json: true))
        #expect(throws: RFBProbeCommand.UsageError.self) { try RFBProbeCommand.Options.parse([]) }
        #expect(throws: RFBProbeCommand.UsageError.self) { try RFBProbeCommand.Options.parse(["h", "port"]) }
        #expect(throws: RFBProbeCommand.UsageError.self) { try RFBProbeCommand.Options.parse(["h", "70000"]) }
    }

    @Test func reportNamesTypesAndThePlan() {
        let hello = RFBServerHello(major: 3, minor: 889, securityTypes: [.appleDiffieHellman, .apple33, .apple36, .apple35],
                                   failureReason: nil)
        let text = RFBProbeCommand.report(hello, host: "127.0.0.1", port: 5901)
        #expect(text.contains("RFB 3.889 (macOS Screen Sharing)"))
        #expect(text.contains("30 Apple Remote Desktop DH (30)  in-app: yes"))
        #expect(text.contains("33 Apple (33)  in-app: no"))
        #expect(text.contains("Mac account entry: in the app with Apple Remote Desktop DH (30)"))
    }

    @Test func serverTextCannotDriveTheTerminal() {
        let hello = RFBServerHello(major: 3, minor: 8, securityTypes: [],
                                   failureReason: "busy\u{1b}]0;owned\u{07}\u{9b}2J" + String(repeating: "x", count: 300))
        let text = RFBProbeCommand.report(hello, host: "h", port: 5900)
        #expect(!text.unicodeScalars.contains { $0.value == 0x1b || $0.value == 0x07 || $0.value == 0x9b })
        #expect(text.contains("busy\\u{1b}]0;owned\\u{7}"))
        #expect(text.contains("…"))
    }

    @Test func jsonReportIsMachineReadableAndHasNoSecrets() throws {
        let hello = RFBServerHello(major: 3, minor: 889, securityTypes: [.apple33, .apple35], failureReason: nil)
        let data = Data(RFBProbeCommand.json(hello).utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? String == "3.889")
        #expect(object["securityTypes"] as? [Int] == [33, 35])
        #expect(object["macAccountPlan"] as? String == "screen-sharing-app-only")
        #expect(Set(object.keys) == ["version", "securityTypes", "macAccountPlan", "vncPasswordPlan", "failureReason"])
    }

    @Test func runsAgainstAServer() async throws {
        let server = try await FakeRFBServer.start(greeting: "RFB 003.008\n", security: [1, 2])
        let (code, out) = await RFBProbeCommand.run(["127.0.0.1", String(server.port)])
        #expect(code == 0)
        #expect(out.contains("2 VNC password (2)  in-app: yes"))
        await server.close()
        let (failed, message) = await RFBProbeCommand.run(["127.0.0.1", "1"])
        #expect(failed == 1)
        #expect(message.hasPrefix("rssh-rfb-probe: "))
    }
}
