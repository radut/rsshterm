import Crypto
import _CryptoExtras
import Foundation

/// Why a key could not be offered or could not sign.
public enum AgentKeyError: Error, Equatable, Sendable {
    /// Not a private key, or a key the agent cannot read (the message says why).
    case unusable(String)
    /// An encrypted key without its passphrase in the vault.
    case passphraseMissing
    case signingFailed
}

/// A vault key the forwarded agent offers: its public blob for the identity list and the private material to sign.
/// The private key never leaves this value; only signatures go to the server.
public struct AgentKey: Identifiable, Sendable {
    /// The credential's id.
    public let id: UUID
    /// The credential's label, shown in the confirm prompt.
    public let label: String
    public let identity: AgentIdentity
    let material: PrivateKeyMaterial

    public var keyType: String { material.keyType }

    init(id: UUID, label: String, material: PrivateKeyMaterial, comment: String) {
        self.id = id
        self.label = label
        self.material = material
        self.identity = AgentIdentity(publicBlob: material.publicBlob, comment: comment.isEmpty ? label : comment)
    }

    /// Reads a vault key. `decrypt` turns an encrypted key and its passphrase into the plain private section (the
    /// app passes Citadel's `OpenSSHPrivateSection.decrypted`); unencrypted keys never call it.
    public static func load(_ credential: Credential,
                            decrypt: (_ pem: String, _ passphrase: String) throws -> Data) throws(AgentKeyError) -> AgentKey {
        guard case .privateKey(let pem, let passphrase) = credential.kind else { throw .unusable("This is a password.") }
        let info: OpenSSHKeyInfo
        do { info = try OpenSSHPrivateKey.inspect(pem) } catch { throw .unusable(error.errorDescription ?? "") }
        if info.isEncrypted, (passphrase ?? "").isEmpty { throw .passphraseMissing }
        do {
            let (material, comment) = try OpenSSHPrivateKey.decode(pem) { try decrypt($0, passphrase ?? "") }
            return AgentKey(id: credential.id, label: credential.label, material: material, comment: comment)
        } catch {
            throw .unusable(error.errorDescription ?? "")
        }
    }

    /// The SSH signature blob (string algorithm, string signature) over `data`. RSA uses SHA-512 or SHA-256 when the
    /// flags ask for it and SHA-1 ("ssh-rsa") only when they ask for neither.
    public func sign(_ data: Data, flags: UInt32) throws(AgentKeyError) -> Data {
        do {
            let (algorithm, signature) = try rawSignature(data, flags: flags)
            var writer = SSHWireWriter()
            writer.string(algorithm)
            writer.string(signature)
            return writer.data
        } catch {
            throw .signingFailed
        }
    }

    /// The algorithm name the signature for these flags carries.
    public func signatureAlgorithm(flags: UInt32) -> String {
        guard case .rsa = material else { return keyType }
        if flags & AgentMessage.rsaSHA2_512 != 0 { return "rsa-sha2-512" }
        if flags & AgentMessage.rsaSHA2_256 != 0 { return "rsa-sha2-256" }
        return "ssh-rsa"
    }

    private func rawSignature(_ data: Data, flags: UInt32) throws -> (String, Data) {
        switch material {
        case .ed25519(let seed, _):
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return (keyType, try key.signature(for: data))
        case .ecdsa(let curve, let scalar, _):
            return (keyType, try Self.ecdsaSignature(curve: curve, scalar: scalar, data: data))
        case .rsa(let fields):
            let key = try _RSA.Signing.PrivateKey(n: fields.n, e: fields.e, d: fields.d, p: fields.p, q: fields.q)
            let algorithm = signatureAlgorithm(flags: flags)
            let signature: _RSA.Signing.RSASignature = switch algorithm {
            case "rsa-sha2-512": try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
            case "rsa-sha2-256": try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
            default: try key.signature(for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5)
            }
            return (algorithm, signature.rawRepresentation)
        }
    }

    /// RFC 5656 §3.1.2: the signature is string(mpint r, mpint s); the curve picks the hash (SHA-256/384/512).
    private static func ecdsaSignature(curve: ECCurve, scalar: [UInt8], data: Data) throws -> Data {
        let raw: Data = switch curve {
        case .p256: try P256.Signing.PrivateKey(rawRepresentation: scalar).signature(for: data).rawRepresentation
        case .p384: try P384.Signing.PrivateKey(rawRepresentation: scalar).signature(for: data).rawRepresentation
        case .p521: try P521.Signing.PrivateKey(rawRepresentation: scalar).signature(for: data).rawRepresentation
        }
        let half = raw.count / 2
        var inner = SSHWireWriter()
        inner.mpint(Array(raw.prefix(half)))
        inner.mpint(Array(raw.suffix(half)))
        return inner.data
    }
}
