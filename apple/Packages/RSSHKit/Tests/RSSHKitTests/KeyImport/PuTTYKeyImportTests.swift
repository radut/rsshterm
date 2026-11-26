import Foundation
import Testing
@testable import RSSHKit

@Suite struct PuTTYKeyImportTests {
    typealias V = PuTTYKeyVectors
    typealias Check = KeyImportCheck

    @Test(arguments: [(V.rsaV2, 2), (V.rsaV3, 3)])
    func unencryptedRSAIsTheSameKeyAsThePEM(_ ppk: String, version: Int) throws {
        let key = try Check.converts(ppk, to: RSAKeyVectors.publicLine, format: .putty(version))
        #expect(key.info.comment == "rsa@putty")
        let fromPEM = try KeyImport.convert(RSAKeyVectors.pkcs1, passphrase: nil, comment: "")
        #expect(try OpenSSHPrivateKey.decode(key.pem).key == OpenSSHPrivateKey.decode(fromPEM.pem).key)
    }

    @Test func encryptedV2OpensWithThePassphrase() throws {
        _ = try Check.converts(V.rsaV2Encrypted, passphrase: "pass", to: RSAKeyVectors.publicLine, format: .putty(2))
        #expect(throws: KeyImportError.wrongPassphrase(.putty(2))) {
            try KeyImport.convert(V.rsaV2Encrypted, passphrase: "nope", comment: "")
        }
        #expect(throws: KeyImportError.passphraseRequired(.putty(2))) {
            try KeyImport.convert(V.rsaV2Encrypted, passphrase: nil, comment: "")
        }
    }

    @Test func argon2IsExplainedWithTheConversionCommand() {
        #expect(throws: KeyImportError.unsupportedKeyDerivation(.putty(3), "Argon2id")) {
            try KeyImport.convert(V.rsaV3Encrypted, passphrase: "pass", comment: "")
        }
        let message = KeyImportError.unsupportedKeyDerivation(.putty(3), "Argon2id").errorDescription ?? ""
        #expect(message.contains("PuTTY (.ppk v3)") && message.contains("puttygen key.ppk -O private-openssh"))
    }

    @Test func ed25519AndECDSAConvert() throws {
        let ed = try Check.converts(V.ed25519V3, to: V.ed25519PublicLine, format: .putty(3))
        #expect(ed.info.publicLine == V.ed25519PublicLine)
        let p256 = try Check.converts(V.p256V3, to: V.p256PublicLine, format: .putty(3))
        #expect(p256.info.publicLine == V.p256PublicLine)
        let p384 = try Check.converts(V.p384V2, to: V.p384PublicLine, format: .putty(2))
        #expect(p384.info.publicLine == V.p384PublicLine)
    }

    @Test func previewReadsTheHeaders() throws {
        #expect(try KeyImport.preview(V.rsaV2Encrypted)
            == KeyImportPreview(format: .putty(2), keyType: "ssh-rsa", isEncrypted: true, comment: "rsa@putty"))
    }

    @Test func toleratesCRLFAndRewrapping() throws {
        let crlf = V.ed25519V3.replacingOccurrences(of: "\n", with: "\r\n")
        // The public section as one long line, as a clipboard that drops soft wraps leaves it.
        let lines: [String] = V.rsaV3.split(separator: "\n").map(String.init)
        let publicEnd = try #require(lines.firstIndex { $0.hasPrefix("Private-Lines") })
        let head: [String] = Array(lines[..<4])
        let publicSection: String = lines[4..<publicEnd].joined()
        let tail: [String] = Array(lines[publicEnd...])
        let joined = (head + [publicSection] + tail).joined(separator: "\n")
        #expect(Check.publicLine(try KeyImport.convert(crlf, passphrase: nil, comment: "")) == Check.bare(V.ed25519PublicLine))
        #expect(Check.publicLine(try KeyImport.convert(joined, passphrase: nil, comment: "")) == RSAKeyVectors.publicLine)
    }

    @Test func tamperedFileFailsItsMAC() {
        let tampered = V.ed25519V3.replacingOccurrences(of: "Comment: ed@putty", with: "Comment: someone else")
        #expect(throws: KeyImportError.damaged(.putty(3))) { try KeyImport.convert(tampered, passphrase: nil, comment: "") }
    }
}
