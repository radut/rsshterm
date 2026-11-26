import Foundation
import RSSHKit

/// One line of the Keys view: what is safe to show without re-authentication (name, type, fingerprint, public key).
/// The private text is only read on demand, after the master password (`privateText`).
public struct KeyRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let keyType: String
    /// `SHA256:…`, as `ssh-keygen -lf` prints it; empty when the key cannot be read.
    public let fingerprint: String
    /// The `authorized_keys` line, nil when the key cannot be read.
    public let publicLine: String?
    public let isEncrypted: Bool
    /// Why the key cannot be read (it is not offered by the agent either).
    public let problem: String?

    /// The vault's private keys (passwords are not keys), in vault order.
    public static func rows(for credentials: [Credential]) -> [KeyRow] {
        credentials.compactMap { credential in
            guard case .privateKey(let pem, _) = credential.kind else { return nil }
            do {
                let info = try OpenSSHPrivateKey.inspect(pem)
                return KeyRow(id: credential.id, label: credential.label, keyType: info.keyType,
                              fingerprint: HostKeyFingerprint.sha256(blob: info.publicKeyBlob),
                              publicLine: SSHPublicKey.line(type: info.keyType, blob: info.publicKeyBlob,
                                                            comment: info.comment ?? credential.label),
                              isEncrypted: info.isEncrypted, problem: nil)
            } catch {
                return KeyRow(id: credential.id, label: credential.label, keyType: "unknown", fingerprint: "",
                              publicLine: nil, isEncrypted: false,
                              problem: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    /// The private key text of credential `id`; the UI calls this only after re-authentication.
    public static func privateText(of id: UUID, in credentials: [Credential]) -> String? {
        guard let c = credentials.first(where: { $0.id == id }), case .privateKey(let pem, _) = c.kind else { return nil }
        return pem
    }
}
