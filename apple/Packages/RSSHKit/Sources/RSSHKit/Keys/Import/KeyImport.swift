import Foundation

/// What the import sheet shows about pasted key text before it is converted.
public struct KeyImportPreview: Equatable, Sendable {
    public let format: KeyFormat
    /// The SSH key type (`ssh-rsa`, `ecdsa-sha2-nistp256`, …); nil while an encrypted PEM body hides it.
    public let keyType: String?
    public let isEncrypted: Bool
    public let comment: String?
}

/// A key ready for the vault: always in the OpenSSH format, so storage, login and export never see anything else.
public struct ImportedKey: Equatable, Sendable {
    public let pem: String
    /// Kept only for an encrypted OpenSSH key, which stays encrypted; every converted key is stored decrypted.
    public let passphrase: String?
    public let format: KeyFormat
    public let info: OpenSSHKeyInfo
}

/// Reads private keys in the formats people actually have (OpenSSH, PEM PKCS#1 / SEC1 / PKCS#8, encrypted or not,
/// and PuTTY .ppk) and turns them into unencrypted `openssh-key-v1` text. The vault that stores the result is itself
/// encrypted, the same place a passphrase would be kept.
public enum KeyImport {
    public static func preview(_ text: String) throws(KeyImportError) -> KeyImportPreview {
        switch try locate(text) {
        case .openSSH:
            let info = try openSSHInfo(text)
            return KeyImportPreview(format: .openSSH, keyType: info.keyType, isEncrypted: info.isEncrypted,
                                    comment: info.comment)
        case .pem(let block, let format):
            if isEncrypted(block, format) {
                return KeyImportPreview(format: format, keyType: nil, isEncrypted: true, comment: nil)
            }
            let key = try material(block, format: format, passphrase: nil)
            return KeyImportPreview(format: format, keyType: key.keyType, isEncrypted: false, comment: nil)
        case .putty(let key):
            return KeyImportPreview(format: key.format, keyType: key.keyType, isEncrypted: key.isEncrypted,
                                    comment: key.comment)
        }
    }

    /// The key as OpenSSH text. `comment` is used for formats that carry none (PEM); PuTTY keys keep their own.
    public static func convert(_ text: String, passphrase: String?, comment: String) throws(KeyImportError)
        -> ImportedKey {
        let phrase = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        let (format, key, keyComment): (KeyFormat, PrivateKeyMaterial, String)
        switch try locate(text) {
        case .openSSH:
            let info = try openSSHInfo(text)
            guard let pem = try? OpenSSHPrivateKey.normalized(text) else { throw .damaged(.openSSH) }
            return ImportedKey(pem: pem, passphrase: info.isEncrypted ? phrase : nil, format: .openSSH, info: info)
        case .pem(let block, let pemFormat):
            (format, key, keyComment) = (pemFormat, try material(block, format: pemFormat, passphrase: phrase), comment)
        case .putty(let putty):
            let own = putty.comment.trimmingCharacters(in: .whitespaces)
            (format, key, keyComment) = (putty.format, try putty.material(passphrase: phrase), own.isEmpty ? comment : own)
        }
        let pem = OpenSSHPrivateKey.encode(key, comment: keyComment)
        guard let info = try? OpenSSHPrivateKey.inspect(pem) else { throw .damaged(format) }
        return ImportedKey(pem: pem, passphrase: nil, format: format, info: info)
    }

    // MARK: - Private

    private enum Source {
        case openSSH
        case pem(PEMBlock, KeyFormat)
        case putty(PuTTYKey)
    }

    private static func locate(_ text: String) throws(KeyImportError) -> Source {
        if text.contains(PuTTYKey.marker) { return .putty(try PuTTYKey.parse(text)) }
        guard let label = PEMArmor.firstLabel(in: text) else {
            throw looksLikePublicKey(text) ? .publicKeyOnly : .unrecognized
        }
        let format: KeyFormat
        switch label {
        case "OPENSSH PRIVATE KEY": return .openSSH
        case "RSA PRIVATE KEY": format = .pkcs1RSA
        case "EC PRIVATE KEY": format = .sec1EC
        case "PRIVATE KEY": format = .pkcs8
        case "ENCRYPTED PRIVATE KEY": format = .pkcs8Encrypted
        case "DSA PRIVATE KEY": throw .unsupportedKeyType(.pem(label), "DSA")
        case _ where label.hasSuffix("PUBLIC KEY"): throw .publicKeyOnly
        case _ where label.hasSuffix("PRIVATE KEY"): throw .unsupportedKeyType(.pem(label), label)
        default: throw .unrecognized
        }
        switch PEMArmor.block(in: text) {
        case .success(let block): return .pem(block, format)
        case .failure, nil: throw .damaged(format)
        }
    }

    private static func looksLikePublicKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["ssh-rsa ", "ssh-ed25519 ", "ecdsa-sha2-", "ssh-dss ", "---- BEGIN SSH2 PUBLIC KEY"]
            .contains { trimmed.hasPrefix($0) }
    }

    private static func openSSHInfo(_ text: String) throws(KeyImportError) -> OpenSSHKeyInfo {
        do { return try OpenSSHPrivateKey.inspect(text) } catch { throw .damaged(.openSSH) }
    }

    private static func isEncrypted(_ block: PEMBlock, _ format: KeyFormat) -> Bool {
        format == .pkcs8Encrypted || block.dekInfo != nil
    }

    private static func material(_ block: PEMBlock, format: KeyFormat, passphrase: String?) throws(KeyImportError)
        -> PrivateKeyMaterial {
        var der = block.body
        var decrypted = false
        if isEncrypted(block, format) {
            guard let passphrase else { throw .passphraseRequired(format) }
            do {
                if let dek = block.dekInfo {
                    der = try PEMDecryption.legacy(der, cipher: dek.cipher, iv: dek.iv, passphrase: passphrase)
                } else {
                    der = try PEMDecryption.pbes2(der, passphrase: passphrase)
                }
            } catch {
                switch error {
                case .wrongPassphrase: throw .wrongPassphrase(format)
                case .unsupportedCipher(let cipher): throw .unsupportedCipher(format, cipher)
                case .malformed: throw .damaged(format)
                }
            }
            decrypted = true
        }
        do {
            switch format {
            case .pkcs1RSA: return try DERPrivateKeys.pkcs1RSA(der)
            case .sec1EC: return try DERPrivateKeys.sec1EC(der)
            default: return try DERPrivateKeys.pkcs8(der)
            }
        } catch {
            switch error {
            case .unsupportedKeyType(let type): throw .unsupportedKeyType(format, type)
            // Garbage after a successful unpad is a wrong passphrase that happened to leave valid padding.
            case .malformed: throw decrypted ? .wrongPassphrase(format) : .damaged(format)
            }
        }
    }
}
