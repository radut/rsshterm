import Citadel
import Crypto
import Foundation
import RSSHKit

/// Turns a vault credential into a Citadel authentication method, with readable errors for bad keys.
/// `LoginKey.plan` checks the key header first; Citadel's OpenSSH parser then decodes ed25519 and RSA keys, including
/// passphrase protected ones (bcrypt KDF, AES-CTR). ECDSA keys (unencrypted, as every imported PEM/PuTTY key is
/// stored) are read by RSSHKit and handed to swift-crypto.
public enum SSHAuthFactory {
    public static func method(username: String, secret: Credential.Kind) throws(SSHFailure) -> SSHAuthenticationMethod {
        switch secret {
        case .password(let password):
            return .passwordBased(username: username, password: password)
        case .privateKey(let pem, let passphrase):
            let plan = try LoginKey.plan(pem: pem, passphrase: passphrase)
            return try keyMethod(username: username, pem: pem, plan: plan)
        }
    }

    private static func keyMethod(username: String, pem: String, plan: LoginKey) throws(SSHFailure) -> SSHAuthenticationMethod {
        let (algorithm, passphrase): (LoginKey.Algorithm, String?)
        switch plan { case .openSSH(let a, let p): (algorithm, passphrase) = (a, p) }
        let decryptionKey = passphrase.map { Data($0.utf8) }
        do {
            switch algorithm {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: decryptionKey)
                return .ed25519(username: username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: decryptionKey)
                return .rsa(username: username, privateKey: key)
            case .ecdsa(let curve):
                return try ecdsaMethod(username: username, pem: pem, curve: curve)
            }
        } catch {
            // An encrypted key that fails its check bytes almost always means a wrong passphrase.
            throw passphrase == nil ? .invalidKey(OpenSSHKeyError.malformed.errorDescription ?? "") : .wrongPassphrase
        }
    }

    private static func ecdsaMethod(username: String, pem: String, curve: ECCurve) throws -> SSHAuthenticationMethod {
        let (decoded, scalar) = try OpenSSHPrivateKey.decodeECDSA(pem)
        guard decoded == curve else { throw OpenSSHKeyError.malformed }
        switch curve {
        case .p256: return .p256(username: username, privateKey: try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case .p384: return .p384(username: username, privateKey: try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case .p521: return .p521(username: username, privateKey: try P521.Signing.PrivateKey(rawRepresentation: scalar))
        }
    }
}
