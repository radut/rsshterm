import Foundation

/// Password and key edits. A credential a server still logs in with cannot be deleted.
extension Vault {
    public func addingCredential(_ credential: Credential) throws(VaultEditError) -> Vault {
        guard !credentials.contains(where: { $0.id == credential.id }) else { throw .duplicateID }
        return with(credentials: credentials + [try Self.checked(credential)])
    }

    public func updatingCredential(_ credential: Credential) throws(VaultEditError) -> Vault {
        guard let index = credentials.firstIndex(where: { $0.id == credential.id }) else { throw .unknownCredential }
        var updated = credentials
        updated[index] = try Self.checked(credential)
        return with(credentials: updated)
    }

    public func deletingCredential(_ id: UUID) throws(VaultEditError) -> Vault {
        guard credentials.contains(where: { $0.id == id }) else { throw .unknownCredential }
        let users = servers.filter { $0.credentialID == id }.map(\.name)
            + remoteDesktops.filter { $0.credentialID == id }.map(\.name)
        guard users.isEmpty else { throw .credentialInUse(users) }
        return with(credentials: credentials.filter { $0.id != id })
    }

    /// The servers that log in with this credential.
    public func servers(using credentialID: UUID) -> [Server] {
        servers.filter { $0.credentialID == credentialID }
    }

    private static func checked(_ credential: Credential) throws(VaultEditError) -> Credential {
        let label = credential.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw .emptyName }
        switch credential.kind {
        case .password(let secret):
            guard !secret.isEmpty else { throw .emptySecret }
        case .privateKey(let pem, _):
            do { _ = try OpenSSHPrivateKey.inspect(pem) } catch { throw .invalidKey(error.errorDescription ?? "") }
        }
        return Credential(id: credential.id, label: label, kind: credential.kind)
    }
}

extension Credential {
    public var isPassword: Bool {
        if case .password = kind { return true }
        return false
    }

    public var isPrivateKey: Bool { !isPassword }

    /// What can be shown about a key without its secret: type, comment and the public line. Nil for passwords.
    public var keyInfo: OpenSSHKeyInfo? {
        guard case .privateKey(let pem, _) = kind else { return nil }
        return try? OpenSSHPrivateKey.inspect(pem)
    }
}
