import Foundation

/// How to log in with a stored private key, decided from its unencrypted header before any crypto runs.
public enum LoginKey: Equatable, Sendable {
    public enum Algorithm: Equatable, Sendable { case ed25519, rsa, ecdsa(ECCurve) }

    /// Decode `pem` as this algorithm, with `passphrase` when the key is encrypted (bcrypt KDF). ECDSA keys are read
    /// by `OpenSSHPrivateKey.decodeECDSA`, so only unencrypted ones (every imported PEM/PuTTY key) can log in.
    case openSSH(Algorithm, passphrase: String?)

    /// Checks the key text and passphrase; throws a failure with a message for the user.
    public static func plan(pem: String, passphrase: String?) throws(SSHFailure) -> LoginKey {
        let info: OpenSSHKeyInfo
        do { info = try OpenSSHPrivateKey.inspect(pem) } catch {
            throw .invalidKey(error.errorDescription ?? "The private key could not be read.")
        }
        let algorithm: Algorithm
        switch info.keyType {
        case SSHPublicKey.ed25519Type: algorithm = .ed25519
        case "ssh-rsa": algorithm = .rsa
        default:
            guard let curve = ECCurve(keyType: info.keyType), !info.isEncrypted else {
                throw .unsupportedKey(info.keyType)
            }
            algorithm = .ecdsa(curve)
        }
        guard info.isEncrypted else { return .openSSH(algorithm, passphrase: nil) }
        guard let passphrase, !passphrase.isEmpty else { throw .passphraseRequired }
        return .openSSH(algorithm, passphrase: passphrase)
    }
}
