import Foundation
import Testing
@testable import RSSHKit

@Suite struct ECKeyImportTests {
    typealias V = ECKeyVectors
    typealias Check = KeyImportCheck

    @Test func sec1P256IsTheSameKeySSHKeygenWrites() throws {
        let key = try Check.converts(V.p256SEC1, to: V.p256PublicLine, format: .sec1EC)
        #expect(key.info.keyType == "ecdsa-sha2-nistp256")
        #expect(try Check.matchesSSHKeygen(key, openSSH: V.p256OpenSSH))
    }

    @Test func missingPublicPointIsComputed() throws {
        let key = try Check.converts(V.p256SEC1NoPublic, to: V.p256PublicLine, format: .sec1EC)
        #expect(try Check.matchesSSHKeygen(key, openSSH: V.p256OpenSSH))
    }

    @Test func pkcs8P256IsTheSameKey() throws {
        let key = try Check.converts(V.p256PKCS8, to: V.p256PublicLine, format: .pkcs8)
        #expect(try Check.matchesSSHKeygen(key, openSSH: V.p256OpenSSH))
    }

    @Test func encryptedECKeysOpenWithThePassphrase() throws {
        _ = try Check.converts(V.p256SEC1AES128, passphrase: "pass", to: V.p256PublicLine, format: .sec1EC)
        _ = try Check.converts(V.p256PKCS8Encrypted, passphrase: "pass", to: V.p256PublicLine, format: .pkcs8Encrypted)
        #expect(throws: KeyImportError.wrongPassphrase(.sec1EC)) {
            try KeyImport.convert(V.p256SEC1AES128, passphrase: "nope", comment: "")
        }
        #expect(throws: KeyImportError.wrongPassphrase(.pkcs8Encrypted)) {
            try KeyImport.convert(V.p256PKCS8Encrypted, passphrase: "nope", comment: "")
        }
    }

    @Test func p384AndP521Convert() throws {
        #expect(try Check.converts(V.p384PKCS8, to: V.p384PublicLine, format: .pkcs8).info.keyType
            == "ecdsa-sha2-nistp384")
        #expect(try Check.converts(V.p521SEC1, to: V.p521PublicLine, format: .sec1EC).info.keyType
            == "ecdsa-sha2-nistp521")
    }

    @Test func ed25519PKCS8Converts() throws {
        let key = try Check.converts(V.ed25519PKCS8, to: V.ed25519PublicLine, format: .pkcs8)
        #expect(try OpenSSHPrivateKey.decodeEd25519(key.pem).publicLine == V.ed25519PublicLine)
        _ = try Check.converts(V.ed25519PKCS8Encrypted, passphrase: "pass", to: V.ed25519PublicLine,
                               format: .pkcs8Encrypted)
    }

    @Test func convertedECDSAKeysCanLogIn() throws {
        let key = try KeyImport.convert(V.p256SEC1, passphrase: nil, comment: "")
        let (curve, scalar) = try OpenSSHPrivateKey.decodeECDSA(key.pem)
        #expect(curve == .p256 && scalar.count == 32)
        #expect(try LoginKey.plan(pem: key.pem, passphrase: nil) == .openSSH(.ecdsa(.p256), passphrase: nil))
    }

    @Test func keysThatCannotLogInAreNamed() {
        #expect(throws: KeyImportError.unsupportedKeyType(.pkcs8, "X25519")) {
            try KeyImport.convert(V.x25519PKCS8, passphrase: nil, comment: "")
        }
        let dsa = "-----BEGIN DSA PRIVATE KEY-----\nMIIBuwIBAAKBgQ==\n-----END DSA PRIVATE KEY-----\n"
        #expect(throws: KeyImportError.unsupportedKeyType(.pem("DSA PRIVATE KEY"), "DSA")) {
            try KeyImport.convert(dsa, passphrase: nil, comment: "")
        }
    }
}
