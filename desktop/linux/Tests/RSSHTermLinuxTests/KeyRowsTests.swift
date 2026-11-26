import Foundation
import RSSHKit
import Testing
@testable import RSSHTermLinux

@Suite struct KeyRowsTests {
    // ssh-keygen -t ed25519 -N '' -C test@example (throwaway, generated for this test only)
    static let pem = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACAEa35G4frMhgPlCpe0OOjvtpxG38VJzX4Z0jVlDpydKwAAAJDNYOVpzWDl
    aQAAAAtzc2gtZWQyNTUxOQAAACAEa35G4frMhgPlCpe0OOjvtpxG38VJzX4Z0jVlDpydKw
    AAAEDtu5XaVSW1znQTV7VHjkuE5mgSrbQSXLtsrR1lXRue/gRrfkbh+syGA+UKl7Q46O+2
    nEbfxUnNfhnSNWUOnJ0rAAAADHRlc3RAZXhhbXBsZQE=
    -----END OPENSSH PRIVATE KEY-----
    """

    @Test func listsKeysNotPasswords() throws {
        let key = Credential(label: "laptop", kind: .privateKey(pem: Self.pem, passphrase: nil))
        let pw = Credential(label: "pw", kind: .password("x"))
        let rows = KeyRow.rows(for: [pw, key])
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.label == "laptop")
        #expect(row.keyType == "ssh-ed25519")
        #expect(row.fingerprint.hasPrefix("SHA256:"))
        #expect(row.publicLine?.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5") == true)
        #expect(!row.isEncrypted)
        #expect(row.problem == nil)
    }

    @Test func unreadableKeyStillListedWithAProblem() throws {
        let bad = Credential(label: "broken", kind: .privateKey(pem: "not a key", passphrase: nil))
        let row = try #require(KeyRow.rows(for: [bad]).first)
        #expect(row.publicLine == nil)
        #expect(row.problem != nil)
        #expect(row.fingerprint == "")
    }

    @Test func privateTextComesOnlyFromTheVault() throws {
        let key = Credential(label: "laptop", kind: .privateKey(pem: Self.pem, passphrase: nil))
        #expect(KeyRow.privateText(of: key.id, in: [key]) == Self.pem)
        #expect(KeyRow.privateText(of: UUID(), in: [key]) == nil)
    }
}
