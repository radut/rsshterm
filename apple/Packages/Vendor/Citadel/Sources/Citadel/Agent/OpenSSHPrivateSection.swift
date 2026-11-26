import Foundation
import NIO
import NIOSSH

// rSSH patch (see PATCHES.md): exposes the bcrypt + AES-CTR decryption Citadel already does for its own key types,
// for any key type, so an app can read encrypted ECDSA/RSA/ed25519 keys with its own parser.

public enum OpenSSHPrivateSection {
    /// The private section of an OpenSSH private key ("openssh-key-v1"), decrypted: the two check integers, the
    /// key type, the key fields, the comment and the padding, as PROTOCOL.key lays them out. For an unencrypted key
    /// it is returned as stored. Throws when the passphrase is missing or wrong (the check integers differ).
    public static func decrypted(_ pem: String, passphrase: Data?) throws -> Data {
        var key = pem.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----"
        guard key.hasPrefix(begin), key.hasSuffix(end) else { throw InvalidOpenSSHKey.invalidOpenSSHBoundary }
        key.removeLast(end.utf8.count)
        key.removeFirst(begin.utf8.count)
        guard let data = Data(base64Encoded: key.replacingOccurrences(of: " ", with: "")) else {
            throw InvalidOpenSSHKey.invalidBase64Payload
        }

        var buffer = ByteBuffer(data: data)
        guard
            buffer.readString(length: "openssh-key-v1".utf8.count) == "openssh-key-v1",
            buffer.readInteger(as: UInt8.self) == 0x00
        else {
            throw InvalidOpenSSHKey.invalidOpenSSHPrefix
        }
        let cipher = try OpenSSH.Cipher(consuming: &buffer)
        let kdf = try OpenSSH.KDF(consuming: &buffer)
        guard buffer.readInteger(as: UInt32.self) == 1 else {
            throw InvalidOpenSSHKey.unsupportedFeature(.multipleKeys)
        }
        guard buffer.readSSHBuffer() != nil else { throw InvalidOpenSSHKey.missingPublicKeyBuffer }
        guard var section = buffer.readSSHBuffer() else { throw InvalidOpenSSHKey.missingPrivateKeyBuffer }

        try kdf.withKeyAndIV(cipher: cipher, basedOnDecryptionKey: passphrase) { key, iv in
            try cipher.decryptBuffer(&section, key: key, iv: iv)
        }
        guard
            let check0 = section.getInteger(at: section.readerIndex, as: UInt32.self),
            let check1 = section.getInteger(at: section.readerIndex + 4, as: UInt32.self),
            check0 == check1
        else {
            throw InvalidOpenSSHKey.invalidCheck
        }
        return Data(section.readableBytesView)
    }
}
