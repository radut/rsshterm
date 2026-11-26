import Foundation
import Testing
@testable import RSSHKit

@Suite struct OpenSSHKeyTests {
    typealias V = OpenSSHKeyVectors

    @Test func decodesTheKnownEd25519Key() throws {
        let key = try OpenSSHPrivateKey.decodeEd25519(V.ed25519PEM)
        #expect(key.comment == "test@rsshkit")
        #expect(key.seed.count == 32)
        #expect(SSHPublicKey.ed25519Line(publicKey: key.publicKey, comment: key.comment) == V.ed25519PublicLine)
    }

    @Test func encodesTheKnownKeyByteForByte() throws {
        let key = try OpenSSHPrivateKey.decodeEd25519(V.ed25519PEM)
        #expect(OpenSSHPrivateKey.encode(key, checkInt: V.ed25519CheckInt) == V.ed25519PEM)
    }

    @Test func seedAloneRebuildsThePublicKey() throws {
        let known = try OpenSSHPrivateKey.decodeEd25519(V.ed25519PEM)
        let rebuilt = try Ed25519KeyPair(seed: known.seed, comment: known.comment)
        #expect(rebuilt == known)
    }

    @Test func generatedKeysRoundTrip() throws {
        let key = Ed25519KeyPair.generate(comment: "rssh@iphone")
        let pem = OpenSSHPrivateKey.encode(key)
        #expect(pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        #expect(pem.split(separator: "\n").allSatisfy { $0.count <= 70 })
        #expect(try OpenSSHPrivateKey.decodeEd25519(pem) == key)
        #expect(key.publicLine.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
        #expect(key.publicLine.hasSuffix(" rssh@iphone"))
    }

    @Test func toleratesWindowsLineEndingsAndSurroundingSpace() throws {
        let messy = "\n  " + V.ed25519PEM.replacingOccurrences(of: "\n", with: "\r\n") + "  \n"
        #expect(try OpenSSHPrivateKey.decodeEd25519(messy).comment == "test@rsshkit")
    }

    @Test func inspectReadsThePublicPartOfAnyKey() throws {
        let plain = try OpenSSHPrivateKey.inspect(V.ed25519PEM)
        #expect(plain.keyType == "ssh-ed25519" && !plain.isEncrypted && plain.comment == "test@rsshkit")
        #expect(plain.publicLine == V.ed25519PublicLine)

        let encrypted = try OpenSSHPrivateKey.inspect(V.encryptedPEM)
        #expect(encrypted.isEncrypted && encrypted.comment == nil)
        #expect(encrypted.publicLine == V.encryptedPublicLine)

        let rsa = try OpenSSHPrivateKey.inspect(V.rsaPEM)
        #expect(rsa.keyType == "ssh-rsa" && !rsa.isEncrypted && rsa.comment == "rsa@x")
        #expect(rsa.publicLine == V.rsaPublicLine + " rsa@x")
    }

    @Test func refusesWhatItCannotDecode() {
        #expect(throws: OpenSSHKeyError.encrypted) { try OpenSSHPrivateKey.decodeEd25519(V.encryptedPEM) }
        #expect(throws: OpenSSHKeyError.unsupportedKeyType("ssh-rsa")) { try OpenSSHPrivateKey.decodeEd25519(V.rsaPEM) }
        #expect(throws: OpenSSHKeyError.notOpenSSHKey) { try OpenSSHPrivateKey.inspect("hello") }
        #expect(throws: OpenSSHKeyError.notOpenSSHKey) {
            try OpenSSHPrivateKey.inspect("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----")
        }
    }

    @Test func truncatedOrCorruptKeysFailCleanly() {
        let lines = V.ed25519PEM.split(separator: "\n")
        let truncated = ([lines[0], lines[1], lines[2]] + [lines.last!]).joined(separator: "\n")
        #expect(throws: OpenSSHKeyError.self) { try OpenSSHPrivateKey.decodeEd25519(truncated) }
        let notBase64 = "-----BEGIN OPENSSH PRIVATE KEY-----\n!!!!\n-----END OPENSSH PRIVATE KEY-----"
        #expect(throws: OpenSSHKeyError.self) { try OpenSSHPrivateKey.inspect(notBase64) }
    }

    @Test func badSeedLengthIsRejected() {
        #expect(throws: OpenSSHKeyError.invalidKeyLength) { try Ed25519KeyPair(seed: Data(count: 31), comment: "") }
    }

    @Test func errorsReadWell() {
        #expect(OpenSSHKeyError.encrypted.errorDescription?.contains("passphrase") == true)
        #expect(OpenSSHKeyError.unsupportedKeyType("ssh-rsa").errorDescription?.contains("ssh-rsa") == true)
    }
}
