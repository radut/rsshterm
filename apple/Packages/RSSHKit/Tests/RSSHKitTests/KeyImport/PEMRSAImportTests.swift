import Foundation
import Testing
@testable import RSSHKit

@Suite struct PEMRSAImportTests {
    typealias V = RSAKeyVectors
    typealias Check = KeyImportCheck

    @Test func pkcs1BecomesTheSameKeySSHKeygenWrites() throws {
        let key = try Check.converts(V.pkcs1, to: V.publicLine, format: .pkcs1RSA)
        #expect(key.info.keyType == "ssh-rsa")
        #expect(try Check.matchesSSHKeygen(key, openSSH: V.openSSH))
    }

    @Test func pkcs8RSAIsTheSameKey() throws {
        let key = try Check.converts(V.pkcs8, to: V.publicLine, format: .pkcs8)
        #expect(try Check.matchesSSHKeygen(key, openSSH: V.openSSH))
    }

    @Test func commentComesFromTheUser() throws {
        let key = try KeyImport.convert(V.pkcs1, passphrase: nil, comment: "laptop")
        #expect(key.info.comment == "laptop")
        #expect(try OpenSSHPrivateKey.decode(key.pem).comment == "laptop")
    }

    @Test(arguments: [V.pkcs1AES128, V.pkcs1AES256])
    func legacyEncryptedPEMOpensWithThePassphrase(_ pem: String) throws {
        let key = try Check.converts(pem, passphrase: "pass", to: V.publicLine, format: .pkcs1RSA)
        #expect(try Check.matchesSSHKeygen(key, openSSH: V.openSSH))
        #expect(throws: KeyImportError.wrongPassphrase(.pkcs1RSA)) {
            try KeyImport.convert(pem, passphrase: "wrong", comment: "")
        }
        #expect(throws: KeyImportError.passphraseRequired(.pkcs1RSA)) {
            try KeyImport.convert(pem, passphrase: nil, comment: "")
        }
        #expect(throws: KeyImportError.passphraseRequired(.pkcs1RSA)) {
            try KeyImport.convert(pem, passphrase: "", comment: "")
        }
    }

    @Test(arguments: [V.pkcs8SHA256AES256, V.pkcs8SHA1AES128])
    func encryptedPKCS8OpensWithThePassphrase(_ pem: String) throws {
        let key = try Check.converts(pem, passphrase: "pass", to: V.publicLine, format: .pkcs8Encrypted)
        #expect(try Check.matchesSSHKeygen(key, openSSH: V.openSSH))
        #expect(throws: KeyImportError.wrongPassphrase(.pkcs8Encrypted)) {
            try KeyImport.convert(pem, passphrase: "wrong", comment: "")
        }
    }

    @Test func tripleDESIsExplainedWithTheConversionCommand() {
        #expect(throws: KeyImportError.unsupportedCipher(.pkcs1RSA, "DES-EDE3-CBC")) {
            try KeyImport.convert(V.pkcs1DES3, passphrase: "pass", comment: "")
        }
        #expect(throws: KeyImportError.unsupportedCipher(.pkcs8Encrypted, "DES-EDE3-CBC")) {
            try KeyImport.convert(V.pkcs8DES3, passphrase: "pass", comment: "")
        }
        let message = KeyImportError.unsupportedCipher(.pkcs1RSA, "DES-EDE3-CBC").errorDescription ?? ""
        #expect(message.contains("PEM RSA (PKCS#1)") && message.contains("ssh-keygen -p -f key"))
    }

    @Test func previewNamesTheFormatBeforeAnyPassphrase() throws {
        #expect(try KeyImport.preview(V.pkcs1)
            == KeyImportPreview(format: .pkcs1RSA, keyType: "ssh-rsa", isEncrypted: false, comment: nil))
        #expect(try KeyImport.preview(V.pkcs1AES128)
            == KeyImportPreview(format: .pkcs1RSA, keyType: nil, isEncrypted: true, comment: nil))
        #expect(try KeyImport.preview(V.pkcs8SHA1AES128).format == .pkcs8Encrypted)
        #expect(try KeyImport.preview(V.pkcs8).keyType == "ssh-rsa")
    }

    @Test func toleratesWhatClipboardsDo() throws {
        let crlf = "  \r\n" + V.pkcs1.replacingOccurrences(of: "\n", with: "\r\n") + "   "
        let noFinalNewline = V.pkcs1.trimmingCharacters(in: .newlines)
        let rewrapped = Check.rewrapped(V.pkcs1, width: 50)
        let oneLine = V.pkcs1.replacingOccurrences(of: "\n", with: " ")
        let indented = V.pkcs1.split(separator: "\n").map { "    \($0)  " }.joined(separator: "\n")
        for text in [crlf, noFinalNewline, rewrapped, oneLine, indented] {
            #expect(Check.publicLine(try KeyImport.convert(text, passphrase: nil, comment: "")) == V.publicLine)
        }
    }

    @Test func encryptedHeadersSurviveJoinedLines() throws {
        let oneLine = V.pkcs1AES128.replacingOccurrences(of: "\n", with: " ")
        let glued = V.pkcs1AES128.replacingOccurrences(of: "\n\n", with: "").replacingOccurrences(of: "\r", with: "")
        let crlf = V.pkcs1AES128.replacingOccurrences(of: "\n", with: "\r\n")
        for text in [oneLine, glued, crlf, Check.rewrapped(V.pkcs1AES128, width: 76)] {
            let key = try KeyImport.convert(text, passphrase: "pass", comment: "")
            #expect(Check.publicLine(key) == V.publicLine)
        }
    }

    @Test func damagedPEMNamesItsFormat() {
        let lines = V.pkcs1.split(separator: "\n")
        let truncated = (lines.prefix(4) + [lines.last!]).joined(separator: "\n")
        #expect(throws: KeyImportError.damaged(.pkcs1RSA)) { try KeyImport.convert(truncated, passphrase: nil, comment: "") }
        let noEnd = lines.dropLast().joined(separator: "\n")
        #expect(throws: KeyImportError.damaged(.pkcs1RSA)) { try KeyImport.convert(noEnd, passphrase: nil, comment: "") }
        let message = KeyImportError.damaged(.pkcs1RSA).errorDescription ?? ""
        #expect(message.contains("PEM RSA (PKCS#1)") && !message.contains("not an OpenSSH"))
    }
}
