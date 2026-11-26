import Foundation
import Testing
@testable import RSSHKit

@Suite struct SSHFailureTests {
    @Test(arguments: [
        SSHFailure.hostUnreachable(host: "h", detail: "refused"), .timedOut(host: "h"), .authenticationFailed,
        .passphraseRequired, .wrongPassphrase, .unsupportedKey("ssh-dss"), .hostKeyRejectedByUser,
        .hostKeyChanged(expected: "SHA256:a", presented: "SHA256:b"), .noCredential, .shellFailed("x"),
        .unknown("boom"),
    ])
    func everyFailureHasAMessage(failure: SSHFailure) {
        #expect(!failure.message.isEmpty)
    }

    @Test func hostKeyChangedShowsBothFingerprints() {
        let m = SSHFailure.hostKeyChanged(expected: "SHA256:old", presented: "SHA256:new").message
        #expect(m.contains("SHA256:old") && m.contains("SHA256:new"))
    }
}

@Suite struct ConnectionTargetTests {
    @Test func validTarget() throws {
        let t = try ConnectionTarget.validated(host: " pi.local ", port: "2222", username: "root")
        #expect(t == ConnectionTarget(host: "pi.local", port: 2222, username: "root"))
        #expect(t.displayName == "root@pi.local:2222")
        #expect(ConnectionTarget(host: "h", port: 22, username: "u").displayName == "u@h")
    }

    @Test func emptyPortMeans22() throws {
        #expect(try ConnectionTarget.validated(host: "h", port: "", username: "u").port == 22)
    }

    @Test(arguments: [("", "22", "u"), ("h", "0", "u"), ("h", "70000", "u"), ("h", "x", "u"), ("h", "22", " "),
                      ("bad host", "22", "u")])
    func invalidTargets(host: String, port: String, user: String) {
        #expect(throws: ConnectionTarget.ValidationError.self) {
            try ConnectionTarget.validated(host: host, port: port, username: user)
        }
    }
}
