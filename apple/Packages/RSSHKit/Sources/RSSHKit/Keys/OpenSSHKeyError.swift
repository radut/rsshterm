import Foundation

/// Why a private key could not be read. Messages are for the user; they never contain key material.
public enum OpenSSHKeyError: Error, Equatable, Sendable, LocalizedError {
    /// Not an `-----BEGIN OPENSSH PRIVATE KEY-----` block (PEM "RSA PRIVATE KEY" and PuTTY files included).
    case notOpenSSHKey
    /// The block is there but its contents are cut off or corrupt.
    case malformed
    /// The key is protected by a passphrase, which this code does not decrypt.
    case encrypted
    case unsupportedKeyType(String)
    /// The two check numbers differ: a wrong passphrase or a damaged file.
    case checkMismatch
    case invalidKeyLength

    public var errorDescription: String? {
        switch self {
        case .notOpenSSHKey:
            "This is not an OpenSSH private key. Paste the text that starts with -----BEGIN OPENSSH PRIVATE KEY-----."
        case .malformed: "The key text is incomplete or damaged. Copy the whole file again."
        case .encrypted: "This key is protected by a passphrase. Enter the passphrase to use it."
        case .unsupportedKeyType(let type): "Keys of type \(type) cannot be read here yet; use an ed25519 key."
        case .checkMismatch: "The key does not check out: it is damaged or the passphrase is wrong."
        case .invalidKeyLength: "The key has the wrong length for ed25519."
        }
    }
}
