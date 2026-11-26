import Foundation
import Testing
@testable import RSSHKit

@Suite struct LoginKeyTests {
    typealias V = OpenSSHKeyVectors

    @Test func plainEd25519NeedsNoPassphrase() throws {
        #expect(try LoginKey.plan(pem: V.ed25519PEM, passphrase: nil) == .openSSH(.ed25519, passphrase: nil))
        // A stray passphrase on an unencrypted key is ignored.
        #expect(try LoginKey.plan(pem: V.ed25519PEM, passphrase: "x") == .openSSH(.ed25519, passphrase: nil))
    }

    @Test func rsaIsRecognised() throws {
        #expect(try LoginKey.plan(pem: V.rsaPEM, passphrase: nil) == .openSSH(.rsa, passphrase: nil))
    }

    @Test func encryptedKeyCarriesItsPassphrase() throws {
        #expect(try LoginKey.plan(pem: V.encryptedPEM, passphrase: "pass") == .openSSH(.ed25519, passphrase: "pass"))
    }

    @Test func encryptedKeyWithoutPassphraseAsksForIt() {
        #expect(throws: SSHFailure.passphraseRequired) { try LoginKey.plan(pem: V.encryptedPEM, passphrase: nil) }
        #expect(throws: SSHFailure.passphraseRequired) { try LoginKey.plan(pem: V.encryptedPEM, passphrase: "") }
    }

    @Test func legacyPEMIsExplained() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIB\n-----END RSA PRIVATE KEY-----"
        #expect(throws: SSHFailure.invalidKey(OpenSSHKeyError.notOpenSSHKey.errorDescription!)) {
            try LoginKey.plan(pem: pem, passphrase: nil)
        }
    }

    @Test func otherAlgorithmsAreUnsupported() {
        #expect(throws: SSHFailure.unsupportedKey("ssh-dss")) {
            try LoginKey.plan(pem: Self.unencryptedPEM(keyType: "ssh-dss"), passphrase: nil)
        }
    }

    /// A structurally valid, unencrypted openssh-key-v1 file of any type; its key bytes are dummies.
    static func unencryptedPEM(keyType: String) -> String {
        let pub = sshString(keyType) + sshString([UInt8](repeating: 1, count: 32))
        var section: [UInt8] = [0, 0, 0, 7, 0, 0, 0, 7] + sshString(keyType) + sshString("comment")
        section += (0..<((8 - section.count % 8) % 8)).map { UInt8($0 + 1) }
        let body = Array("openssh-key-v1\0".utf8) + sshString("none") + sshString("none") + sshString([UInt8]())
            + [0, 0, 0, 1] + sshString(pub) + sshString(section)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(Data(body).base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
