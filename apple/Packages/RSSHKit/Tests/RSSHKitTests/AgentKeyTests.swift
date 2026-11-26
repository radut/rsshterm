import Crypto
import _CryptoExtras
import Foundation
import Testing
@testable import RSSHKit

/// Vault keys as the agent loads them, and their signatures checked with swift-crypto.
@Suite struct AgentKeyTests {
    typealias V = OpenSSHKeyVectors

    static func credential(_ pem: String, passphrase: String? = nil, label: String = "key") -> Credential {
        Credential(label: label, kind: .privateKey(pem: pem, passphrase: passphrase))
    }

    static func imported(_ pem: String) throws -> String {
        try KeyImport.convert(pem, passphrase: nil, comment: "imported").pem
    }

    static let noDecrypt: @Sendable (String, String) throws -> Data = { _, _ in Issue.record("decrypt called"); return Data() }

    @Test func ed25519SignsAndVerifies() throws {
        let key = try AgentKey.load(Self.credential(V.ed25519PEM), decrypt: Self.noDecrypt)
        #expect(key.identity.comment == "test@rsshkit")
        let message = Data("to sign".utf8)
        var reader = SSHWireReader(try key.sign(message, flags: 0))
        #expect(try reader.text() == "ssh-ed25519")
        let signature = try reader.string()
        let decoded = try OpenSSHPrivateKey.decodeEd25519(V.ed25519PEM)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: decoded.publicKey)
        #expect(publicKey.isValidSignature(signature, for: message))
    }

    @Test(arguments: [(UInt32(0), "ssh-rsa"), (AgentMessage.rsaSHA2_256, "rsa-sha2-256"),
                      (AgentMessage.rsaSHA2_512, "rsa-sha2-512"), (UInt32(6), "rsa-sha2-512")])
    func rsaPicksTheHashFromTheFlags(flags: UInt32, algorithm: String) throws {
        let rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let key = try AgentKey.load(Self.credential(try Self.imported(rsa.pemRepresentation)), decrypt: Self.noDecrypt)
        #expect(key.signatureAlgorithm(flags: flags) == algorithm)
        let message = Data("login".utf8)
        var reader = SSHWireReader(try key.sign(message, flags: flags))
        #expect(try reader.text() == algorithm)
        let signature = _RSA.Signing.RSASignature(rawRepresentation: try reader.string())
        let valid = switch algorithm {
        case "rsa-sha2-512": rsa.publicKey.isValidSignature(signature, for: SHA512.hash(data: message), padding: .insecurePKCS1v1_5)
        case "rsa-sha2-256": rsa.publicKey.isValidSignature(signature, for: SHA256.hash(data: message), padding: .insecurePKCS1v1_5)
        default: rsa.publicKey.isValidSignature(signature, for: Insecure.SHA1.hash(data: message), padding: .insecurePKCS1v1_5)
        }
        #expect(valid)
    }

    @Test func ecdsaP256SignsAndVerifies() throws {
        let ec = P256.Signing.PrivateKey()
        let key = try AgentKey.load(Self.credential(try Self.imported(ec.pemRepresentation)), decrypt: Self.noDecrypt)
        #expect(key.keyType == "ecdsa-sha2-nistp256")
        let message = Data("ec".utf8)
        var outer = SSHWireReader(try key.sign(message, flags: AgentMessage.rsaSHA2_512))
        #expect(try outer.text() == "ecdsa-sha2-nistp256")
        var inner = SSHWireReader(try outer.string())
        let r = try inner.mpint(), s = try inner.mpint()
        let pad = { (v: [UInt8]) in [UInt8](repeating: 0, count: 32 - v.count) + v }
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: pad(r) + pad(s))
        #expect(ec.publicKey.isValidSignature(signature, for: message))
    }

    @Test func ecdsaP384AndP521Sign() throws {
        let p384 = try AgentKey.load(Self.credential(try Self.imported(P384.Signing.PrivateKey().pemRepresentation)),
                                     decrypt: Self.noDecrypt)
        let p521 = try AgentKey.load(Self.credential(try Self.imported(P521.Signing.PrivateKey().pemRepresentation)),
                                     decrypt: Self.noDecrypt)
        var a = SSHWireReader(try p384.sign(Data([1]), flags: 0))
        var b = SSHWireReader(try p521.sign(Data([1]), flags: 0))
        #expect(try a.text() == "ecdsa-sha2-nistp384")
        #expect(try b.text() == "ecdsa-sha2-nistp521")
    }

    @Test func passwordsAreNotKeys() {
        #expect(throws: AgentKeyError.unusable("This is a password.")) {
            try AgentKey.load(Credential(label: "pw", kind: .password("x")), decrypt: Self.noDecrypt)
        }
    }

    @Test func encryptedKeyWithoutPassphraseIsRefused() {
        #expect(throws: AgentKeyError.passphraseMissing) {
            try AgentKey.load(Self.credential(V.encryptedPEM), decrypt: Self.noDecrypt)
        }
    }

    @Test func encryptedKeyGoesThroughDecrypt() throws {
        let (pem, section) = try Self.markedEncrypted(V.ed25519PEM)
        var seen: (String, String)?
        let key = try AgentKey.load(Self.credential(pem, passphrase: "secret")) { pem, phrase in
            seen = (pem, phrase)
            return section
        }
        #expect(seen?.1 == "secret")
        #expect(key.identity.comment == "test@rsshkit")
    }

    @Test func wrongDecryptionIsUnusable() throws {
        let (pem, _) = try Self.markedEncrypted(V.ed25519PEM)
        #expect(throws: AgentKeyError.self) {
            try AgentKey.load(Self.credential(pem, passphrase: "x")) { _, _ in Data(repeating: 0xaa, count: 64) }
        }
        #expect(throws: AgentKeyError.self) {
            try AgentKey.load(Self.credential(pem, passphrase: "x")) { _, _ in throw AgentKeyError.signingFailed }
        }
    }

    @Test func identityCommentFallsBackToTheLabel() throws {
        let pem = OpenSSHPrivateKey.encode(Ed25519KeyPair.generate(comment: ""))
        let key = try AgentKey.load(Self.credential(pem, label: "Laptop"), decrypt: Self.noDecrypt)
        #expect(key.identity.comment == "Laptop")
    }

    /// The same key with its header saying aes256-ctr/bcrypt, plus its plain private section: what Citadel's
    /// decryption would hand back for a really encrypted key.
    static func markedEncrypted(_ pem: String) throws -> (String, Data) {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var reader = SSHWireReader(Data(base64Encoded: body)!)
        let magic = Data(try reader.take(OpenSSHPrivateKey.magic.count))
        _ = try reader.text(); _ = try reader.text(); _ = try reader.string()
        let count = try reader.uint32(), blob = try reader.string(), section = try reader.string()
        var writer = SSHWireWriter()
        writer.raw(magic)
        writer.string("aes256-ctr")
        writer.string("bcrypt")
        writer.string(Data(repeating: 0, count: 24))
        writer.uint32(count)
        writer.string(blob)
        writer.string(Data(repeating: 0x5a, count: section.count))
        let armored = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + writer.data.base64EncodedString()
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
        return (armored, section)
    }
}
