import _CryptoExtras
import Crypto
import Foundation

/// Opens passphrase-protected OpenSSH private keys without Citadel: bcrypt_pbkdf derives key and IV, then
/// aes128/192/256-ctr or aes128/256-gcm@openssh.com decrypt the private section (PROTOCOL.key). Its result is what
/// `AgentKey.load(_:decrypt:)` expects, so the desktop agent can offer encrypted vault keys.
public enum OpenSSHKeyDecryption {
    private struct Cipher {
        let keyLength: Int
        let ivLength: Int
        let gcm: Bool
    }

    private static let ciphers: [String: Cipher] = [
        "aes128-ctr": Cipher(keyLength: 16, ivLength: 16, gcm: false),
        "aes192-ctr": Cipher(keyLength: 24, ivLength: 16, gcm: false),
        "aes256-ctr": Cipher(keyLength: 32, ivLength: 16, gcm: false),
        "aes128-gcm@openssh.com": Cipher(keyLength: 16, ivLength: 12, gcm: true),
        "aes256-gcm@openssh.com": Cipher(keyLength: 32, ivLength: 12, gcm: true),
    ]

    /// Most rounds accepted from a key file (ssh-keygen's default is 16; -a 100 is common): a file cannot make an
    /// unlock spin for minutes.
    public static let maximumRounds = 1_000

    /// `AgentKey.load(_:decrypt:)`'s decryptor.
    public static func decrypt(_ pem: String, _ passphrase: String) throws -> Data {
        try decryptedSection(pem, passphrase: passphrase)
    }

    /// The private section in the clear (check numbers, key, comment, padding). Unencrypted keys come back as stored.
    /// A wrong passphrase is `.checkMismatch`; an unknown cipher or KDF is `.encrypted`.
    public static func decryptedSection(_ pem: String, passphrase: String) throws(OpenSSHKeyError) -> Data {
        var reader = SSHWireReader(try OpenSSHPrivateKey.unarmor(pem))
        guard Data(try reader.take(OpenSSHPrivateKey.magic.count)) == OpenSSHPrivateKey.magic else { throw .notOpenSSHKey }
        let cipherName = try reader.text()
        let kdfName = try reader.text()
        let kdfOptions = try reader.string()
        guard try reader.uint32() == 1 else { throw .malformed }
        _ = try reader.string() // public key
        let section = try reader.string()
        if cipherName == "none" { return section }
        guard let cipher = ciphers[cipherName], kdfName == "bcrypt" else { throw .encrypted }

        var options = SSHWireReader(kdfOptions)
        let salt = try options.string()
        let rounds = Int(try options.uint32())
        guard rounds <= maximumRounds else { throw .malformed }
        let material = try BcryptPBKDF.derive(password: Data(passphrase.utf8), salt: salt, rounds: rounds,
                                              length: cipher.keyLength + cipher.ivLength)
        let key = SymmetricKey(data: material.prefix(cipher.keyLength))
        let iv = material.suffix(cipher.ivLength)

        let plain: Data
        do {
            if cipher.gcm {
                let tag = Data(try reader.take(16))
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: section, tag: tag)
                plain = try AES.GCM.open(box, using: key)
            } else {
                plain = try AES._CTR.decrypt(section, using: key, nonce: AES._CTR.Nonce(nonceBytes: iv))
            }
        } catch let error as OpenSSHKeyError {
            throw error
        } catch {
            throw .checkMismatch // GCM: the tag does not verify (wrong passphrase or damaged file)
        }
        var check = SSHWireReader(plain)
        guard try check.uint32() == check.uint32() else { throw .checkMismatch }
        return plain
    }
}
