import Foundation
import Testing
@testable import RSSHKit

/// OpenSSH keys protected by a passphrase (bcrypt_pbkdf + AES-CTR / AES-GCM), read without Citadel.
@Suite struct EncryptedKeyTests {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test func bcryptPBKDFKnownAnswers() throws {
        for (password, salt, rounds, length, expected) in EncryptedKeyVectors.bcryptPBKDF {
            let out = try BcryptPBKDF.derive(password: Data(password.utf8), salt: Data(salt.utf8), rounds: rounds,
                                             length: length)
            #expect(hex(out) == expected, "rounds \(rounds) length \(length)")
        }
    }

    @Test func bcryptPBKDFRejectsBadParameters() {
        #expect(throws: OpenSSHKeyError.self) { _ = try BcryptPBKDF.derive(password: Data("p".utf8), salt: Data(), rounds: 16, length: 32) }
        #expect(throws: OpenSSHKeyError.self) { _ = try BcryptPBKDF.derive(password: Data("p".utf8), salt: Data("s".utf8), rounds: 0, length: 32) }
        #expect(throws: OpenSSHKeyError.self) { _ = try BcryptPBKDF.derive(password: Data("p".utf8), salt: Data("s".utf8), rounds: 16, length: 2000) }
    }

    static let keys: [(String, String, String)] = [
        ("ed25519 aes256-ctr", EncryptedKeyVectors.ed25519, EncryptedKeyVectors.ed25519Public),
        ("ecdsa aes256-ctr", EncryptedKeyVectors.ecdsa, EncryptedKeyVectors.ecdsaPublic),
        ("rsa aes256-ctr", EncryptedKeyVectors.rsa, EncryptedKeyVectors.rsaPublic),
        ("ed25519 aes256-gcm", EncryptedKeyVectors.ed25519GCM, EncryptedKeyVectors.ed25519GCMPublic),
        ("ed25519 aes128-ctr", EncryptedKeyVectors.ed25519AES128, EncryptedKeyVectors.ed25519AES128Public),
    ]

    @Test(arguments: keys)
    func decryptsAndSignsWithTheRightPassphrase(_ key: (String, String, String)) throws {
        let (_, pem, publicLine) = key
        #expect(try OpenSSHPrivateKey.inspect(pem).isEncrypted)
        let credential = Credential(label: "k", kind: .privateKey(pem: pem, passphrase: EncryptedKeyVectors.passphrase))
        let agentKey = try AgentKey.load(credential, decrypt: OpenSSHKeyDecryption.decrypt)
        let parts = publicLine.split(separator: " ")
        #expect(agentKey.keyType == String(parts[0]))
        #expect(agentKey.identity.publicBlob.base64EncodedString() == String(parts[1]))
        #expect(agentKey.identity.comment == String(parts[2]))
        #expect(!(try agentKey.sign(Data("challenge".utf8), flags: 4)).isEmpty)
    }

    @Test(arguments: keys)
    func wrongPassphraseIsACheckMismatch(_ key: (String, String, String)) {
        #expect(throws: OpenSSHKeyError.checkMismatch) {
            _ = try OpenSSHKeyDecryption.decryptedSection(key.1, passphrase: "wrong horse")
        }
    }

    @Test func unencryptedKeyPassesThrough() throws {
        let section = try OpenSSHKeyDecryption.decryptedSection(OpenSSHKeyVectors.ed25519PEM, passphrase: "")
        #expect(section.count > 8)
    }

    @Test func existingVectorOpensWithItsPassphrase() throws {
        let credential = Credential(label: "k", kind: .privateKey(pem: OpenSSHKeyVectors.encryptedPEM, passphrase: "pass"))
        let key = try AgentKey.load(credential, decrypt: OpenSSHKeyDecryption.decrypt)
        #expect(OpenSSHKeyVectors.encryptedPublicLine.hasPrefix("\(key.keyType) \(key.identity.publicBlob.base64EncodedString())"))
    }
}
