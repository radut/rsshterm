import Foundation
import Testing
@testable import RSSHKit

@Suite struct KeyImportTests {
    @Test func openSSHKeysPassThroughNormalized() throws {
        let messy = "\n  " + OpenSSHKeyVectors.ed25519PEM.replacingOccurrences(of: "\n", with: "\r\n") + "  "
        let key = try KeyImport.convert(messy, passphrase: "ignored", comment: "other")
        #expect(key.format == .openSSH && key.pem == OpenSSHKeyVectors.ed25519PEM && key.passphrase == nil)
    }

    @Test func encryptedOpenSSHKeysKeepTheirPassphrase() throws {
        let key = try KeyImport.convert(OpenSSHKeyVectors.encryptedPEM, passphrase: "pass", comment: "")
        #expect(key.passphrase == "pass" && key.info.isEncrypted)
        #expect(try KeyImport.preview(OpenSSHKeyVectors.encryptedPEM).isEncrypted)
    }

    @Test func publicKeysAndOtherTextAreExplained() {
        #expect(throws: KeyImportError.publicKeyOnly) {
            try KeyImport.convert(RSAKeyVectors.publicLine, passphrase: nil, comment: "")
        }
        #expect(throws: KeyImportError.publicKeyOnly) {
            try KeyImport.convert("-----BEGIN PUBLIC KEY-----\nMCowBQ==\n-----END PUBLIC KEY-----", passphrase: nil,
                                  comment: "")
        }
        #expect(throws: KeyImportError.unrecognized) { try KeyImport.convert("hello", passphrase: nil, comment: "") }
        #expect(KeyImportError.unrecognized.errorDescription?.contains("OpenSSH, PEM (RSA/EC/PKCS#8) or PuTTY") == true)
    }

    @Test func noKnownFormatIsCalledNotOpenSSH() {
        let errors: [KeyImportError] = [
            .damaged(.pkcs1RSA), .passphraseRequired(.sec1EC), .wrongPassphrase(.pkcs8Encrypted),
            .unsupportedCipher(.pkcs1RSA, "DES-EDE3-CBC"), .unsupportedKeyType(.pkcs8, "X25519"),
            .unsupportedKeyDerivation(.putty(3), "Argon2id"),
        ]
        for error in errors {
            #expect(error.errorDescription?.contains("not an OpenSSH") == false)
        }
    }

    @Test func derRejectsGarbageWithoutTrapping() {
        for bytes: [UInt8] in [[], [0x30], [0x30, 0x84, 0xff, 0xff, 0xff, 0xff], [0x30, 0x02, 0x02, 0x05], [0x02, 0x00]] {
            #expect(throws: DERKeyFailure.self) { try DERPrivateKeys.pkcs8(bytes) }
            #expect(throws: DERKeyFailure.self) { try DERPrivateKeys.pkcs1RSA(bytes) }
            #expect(throws: DERKeyFailure.self) { try DERPrivateKeys.sec1EC(bytes) }
        }
    }

    @Test func evpBytesToKeyMatchesOpenSSL() {
        // `openssl enc -aes-128-cbc -k pass -S 0102030405060708 -P -md md5`
        // key=86A00079BEB5DCA79870668BB0C56A7E iv=B158E10AC9A1EC44CD2FD6CCF7796367 (the IV is the next 16 bytes)
        let bytes = PEMDecryption.evpBytesToKey(password: Array("pass".utf8), salt: [1, 2, 3, 4, 5, 6, 7, 8], length: 32)
        #expect(bytes.map { String(format: "%02X", $0) }.joined()
            == "86A00079BEB5DCA79870668BB0C56A7E" + "B158E10AC9A1EC44CD2FD6CCF7796367")
    }
}
