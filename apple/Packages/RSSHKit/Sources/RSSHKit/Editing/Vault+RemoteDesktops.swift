import Foundation

/// Remote desktop edits. Each returns a new `Vault` and leaves `self` as it was.
extension Vault {
    public func addingRemoteDesktop(_ desktop: RemoteDesktop) throws(VaultEditError) -> Vault {
        guard !remoteDesktops.contains(where: { $0.id == desktop.id }) else { throw .duplicateID }
        return with(remoteDesktops: remoteDesktops + [try checked(desktop)])
    }

    public func updatingRemoteDesktop(_ desktop: RemoteDesktop) throws(VaultEditError) -> Vault {
        guard let index = remoteDesktops.firstIndex(where: { $0.id == desktop.id }) else {
            throw .unknownRemoteDesktop
        }
        var updated = remoteDesktops
        var checkedDesktop = try checked(desktop)
        // A pin belongs to the server it was taken from: another host or port starts over with a question.
        let old = remoteDesktops[index]
        if old.host != checkedDesktop.host || old.port != checkedDesktop.port || old.tunnelServerID != checkedDesktop.tunnelServerID {
            checkedDesktop.pinnedCertificate = nil
        }
        updated[index] = checkedDesktop
        return with(remoteDesktops: updated)
    }

    public func deletingRemoteDesktops(_ ids: Set<UUID>) throws(VaultEditError) -> Vault {
        guard ids.isSubset(of: Set(remoteDesktops.map(\.id))) else { throw .unknownRemoteDesktop }
        return with(remoteDesktops: remoteDesktops.filter { !ids.contains($0.id) })
    }

    /// Trimmed name and host, a port in range, and links that exist: the folder, the tunnel server and a
    /// password (an SSH key cannot open a screen).
    func checked(_ desktop: RemoteDesktop) throws(VaultEditError) -> RemoteDesktop {
        var d = desktop
        d.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        d.host = d.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.name.isEmpty else { throw .emptyName }
        guard !d.host.isEmpty else { throw .invalidAddress(.emptyHost) }
        guard !d.host.contains(where: \.isWhitespace) else { throw .invalidAddress(.invalidHost) }
        guard (1...65535).contains(d.port) else { throw .invalidAddress(.invalidPort) }
        if let groupID = d.groupID, !groups.contains(where: { $0.id == groupID }) { throw .unknownGroup }
        if let serverID = d.tunnelServerID, !servers.contains(where: { $0.id == serverID }) { throw .unknownServer }
        if let owner = d.serverID {
            guard servers.contains(where: { $0.id == owner }) else { throw .unknownServer }
            let service = ScreenService(d.kind)
            if remoteDesktops.contains(where: { $0.serverID == owner && $0.id != d.id && ScreenService($0.kind) == service }) {
                throw .serviceExists(service.title)
            }
        }
        if d.transport != .direct, d.tunnelServerID == nil { throw .needsTunnelServer }
        if let credentialID = d.credentialID {
            guard let credential = credentials.first(where: { $0.id == credentialID }) else {
                throw .unknownCredential
            }
            guard case .password = credential.kind else { throw .needsPassword }
        }
        return d
    }
}
