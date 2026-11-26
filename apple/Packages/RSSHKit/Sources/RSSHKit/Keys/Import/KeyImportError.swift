import Foundation

/// The container a pasted or picked private key came in.
public enum KeyFormat: Equatable, Sendable {
    case openSSH
    /// `-----BEGIN RSA PRIVATE KEY-----`
    case pkcs1RSA
    /// `-----BEGIN EC PRIVATE KEY-----`
    case sec1EC
    /// `-----BEGIN PRIVATE KEY-----`
    case pkcs8
    /// `-----BEGIN ENCRYPTED PRIVATE KEY-----`
    case pkcs8Encrypted
    /// Any other `-----BEGIN … PRIVATE KEY-----` label, such as DSA.
    case pem(String)
    /// A PuTTY `.ppk` file of this version.
    case putty(Int)

    public var name: String {
        switch self {
        case .openSSH: "OpenSSH"
        case .pkcs1RSA: "PEM RSA (PKCS#1)"
        case .sec1EC: "PEM EC (SEC1)"
        case .pkcs8: "PEM PKCS#8"
        case .pkcs8Encrypted: "encrypted PEM PKCS#8"
        case .pem(let label): "PEM \(label)"
        case .putty(let version): "PuTTY (.ppk v\(version))"
        }
    }

    /// The command that turns the file into a plain OpenSSH key on a computer.
    var conversionHint: String {
        switch self {
        case .putty: "puttygen key.ppk -O private-openssh -o key"
        default: "ssh-keygen -p -f key"
        }
    }
}

/// Why a private key could not be imported. Messages are for the user, name the format that was recognised, and never
/// contain key material.
public enum KeyImportError: Error, Equatable, Sendable, LocalizedError {
    /// No private key of any known format in the text.
    case unrecognized
    /// A public key (`ssh-rsa AAAA…`, `BEGIN PUBLIC KEY`) instead of a private one.
    case publicKeyOnly
    /// The format is known but the contents are cut off or corrupt.
    case damaged(KeyFormat)
    case passphraseRequired(KeyFormat)
    case wrongPassphrase(KeyFormat)
    /// Encrypted with a cipher this code cannot run (DES-EDE3-CBC, …).
    case unsupportedCipher(KeyFormat, String)
    /// A key algorithm that cannot log in here (DSA, X25519, another curve, …).
    case unsupportedKeyType(KeyFormat, String)
    /// A passphrase key derivation this code cannot run (PuTTY v3's Argon2).
    case unsupportedKeyDerivation(KeyFormat, String)

    public var errorDescription: String? {
        switch self {
        case .unrecognized:
            "This is not a private key. Paste a private key: OpenSSH, PEM (RSA/EC/PKCS#8) or PuTTY."
        case .publicKeyOnly:
            "This is a public key. Import the private key instead (the file without .pub)."
        case .damaged(let format):
            "The \(format.name) key is incomplete or damaged. Copy the whole file again."
        case .passphraseRequired(let format):
            "This \(format.name) key is protected by a passphrase. Enter the passphrase to import it."
        case .wrongPassphrase(let format):
            "The passphrase is wrong for this \(format.name) key."
        case .unsupportedCipher(let format, let cipher):
            "This \(format.name) key is encrypted with \(cipher), which cannot be decrypted here. "
                + "Convert it on a computer with: \(format.conversionHint)"
        case .unsupportedKeyType(let format, let type):
            "This \(format.name) key is a \(type) key. Keys of type RSA, ECDSA (P-256, P-384, P-521) "
                + "and Ed25519 can be imported."
        case .unsupportedKeyDerivation(let format, let kdf):
            "This \(format.name) key's passphrase uses \(kdf), which cannot be read here. "
                + "Convert it on a computer with: \(format.conversionHint)"
        }
    }
}
