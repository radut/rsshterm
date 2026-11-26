import Foundation
import Testing
@testable import RSSHKit

@Suite struct QuickLoginTests {
    typealias V = OpenSSHKeyVectors

    func key(_ label: String, _ pem: String, passphrase: String? = nil) -> Credential {
        Credential(label: label, kind: .privateKey(pem: pem, passphrase: passphrase))
    }

    @Test func ed25519KeysComeFirstAndPasswordsAreLeftOut() {
        let rsa = key("rsa", V.rsaPEM)
        let ed = key("ed", V.ed25519PEM)
        let password = Credential(label: "pw", kind: .password("x"))
        let logins = QuickLogin.automatic(from: [rsa, password, ed])
        #expect(logins.map(\.label) == ["ed", "rsa"])
        #expect(logins.first?.credentialID == ed.id)
        #expect(logins.first?.secret == ed.kind)
    }

    @Test func encryptedKeyIsSkippedUnlessItsPassphraseIsStored() {
        let locked = key("locked", V.encryptedPEM)
        let stored = key("stored", V.encryptedPEM, passphrase: "pass")
        #expect(QuickLogin.automatic(from: [locked, stored]).map(\.label) == ["stored"])
    }

    @Test func unreadableKeysAreSkipped() {
        let broken = key("broken", "-----BEGIN RSA PRIVATE KEY-----\nMIIB\n-----END RSA PRIVATE KEY-----")
        #expect(QuickLogin.automatic(from: [broken]).isEmpty)
    }

    @Test func atMostFiveAttempts() {
        let keys = (1...7).map { key("k\($0)", V.ed25519PEM) }
        #expect(QuickLogin.automatic(from: keys).map(\.label) == ["k1", "k2", "k3", "k4", "k5"])
    }

    @Test func onlyCredentialProblemsMoveToTheNextKey() {
        #expect(SSHFailure.authenticationFailed.triesNextLogin)
        #expect(SSHFailure.wrongPassphrase.triesNextLogin)
        #expect(SSHFailure.invalidKey("x").triesNextLogin)
        #expect(!SSHFailure.hostUnreachable(host: "h", detail: "d").triesNextLogin)
        #expect(!SSHFailure.timedOut(host: "h").triesNextLogin)
        #expect(!SSHFailure.hostKeyRejectedByUser.triesNextLogin)
        #expect(!SSHFailure.hostKeyChanged(expected: "a", presented: "b").triesNextLogin)
        #expect(!SSHFailure.shellFailed("x").triesNextLogin)
    }

    @Test func onlyNetworkFailuresReconnectOnTheirOwn() {
        #expect(SSHFailure.hostUnreachable(host: "h", detail: "d").reconnectsAutomatically)
        #expect(SSHFailure.timedOut(host: "h").reconnectsAutomatically)
        #expect(SSHFailure.unknown("connection reset").reconnectsAutomatically)
        #expect(!SSHFailure.authenticationFailed.reconnectsAutomatically)
        #expect(!SSHFailure.passphraseRequired.reconnectsAutomatically)
        #expect(!SSHFailure.wrongPassphrase.reconnectsAutomatically)
        #expect(!SSHFailure.unsupportedKey("dsa").reconnectsAutomatically)
        #expect(!SSHFailure.invalidKey("x").reconnectsAutomatically)
        #expect(!SSHFailure.noCredential.reconnectsAutomatically)
        #expect(!SSHFailure.hostKeyRejectedByUser.reconnectsAutomatically)
        #expect(!SSHFailure.hostKeyChanged(expected: "a", presented: "b").reconnectsAutomatically)
        #expect(!SSHFailure.shellFailed("x").reconnectsAutomatically)
    }

    @Test func savedServerDraftUsesTheAddress() throws {
        let id = UUID()
        let draft = QuickAddress(username: "root", host: "sv1", port: 2200).serverDraft(credentialID: id)
        let server = try draft.makeServer(id: UUID())
        #expect(server.name == "sv1")
        #expect(ConnectionTarget(server: server) == ConnectionTarget(host: "sv1", port: 2200, username: "root"))
        #expect(server.credentialID == id)
    }
}
