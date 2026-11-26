import Foundation

/// Server edits. Each returns a new `Vault` and leaves `self` as it was.
extension Vault {
    /// The servers of one folder (nil: ungrouped), in the order the user arranged them.
    public func servers(inGroup groupID: UUID?) -> [Server] {
        servers.filter { $0.groupID == groupID }
    }

    public func addingServer(_ server: Server) throws(VaultEditError) -> Vault {
        guard !servers.contains(where: { $0.id == server.id }) else { throw .duplicateID }
        try checkLinks(of: server)
        try checkJumps(of: server, in: servers + [server])
        return with(servers: servers + [server])
    }

    public func updatingServer(_ server: Server) throws(VaultEditError) -> Vault {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { throw .unknownServer }
        try checkLinks(of: server)
        var updated = servers
        updated[index] = server
        try checkJumps(of: server, in: updated)
        // Another server whose chain runs through this one may now go round in a circle or get too long.
        for other in updated where other.id != server.id && !other.jumpHosts.isEmpty {
            try checkJumps(of: other, in: updated, only: server.id)
        }
        return with(servers: updated, remoteDesktops: remoteDesktops.map { $0.following(server) })
    }

    public func deletingServers(_ ids: Set<UUID>) throws(VaultEditError) -> Vault {
        guard ids.isSubset(of: Set(servers.map(\.id))) else { throw .unknownServer }
        let users = servers.filter { server in
            !ids.contains(server.id) && server.jumpHosts.contains { if case .server(let id) = $0 { ids.contains(id) } else { false } }
        }
        guard users.isEmpty else { throw .usedAsJumpHost(users.map(\.name)) }
        // A server's own screens go with it; a screen saved elsewhere that tunnels through it blocks the delete.
        let kept = remoteDesktops.filter { !($0.serverID.map(ids.contains) ?? false) }
        let tunnelled = kept.filter { $0.tunnelServerID.map(ids.contains) ?? false }.map(\.name)
        guard tunnelled.isEmpty else { throw .serverInUse(tunnelled) }
        return with(servers: servers.filter { !ids.contains($0.id) }, remoteDesktops: kept)
    }

    public func movingServer(_ id: UUID, toGroup groupID: UUID?) throws(VaultEditError) -> Vault {
        guard var server = servers.first(where: { $0.id == id }) else { throw .unknownServer }
        server.groupID = groupID
        return try updatingServer(server)
    }

    /// Reorders the servers of one folder, with SwiftUI `onMove` offsets (relative to that folder's list).
    public func movingServers(inGroup groupID: UUID?, fromOffsets source: IndexSet, toOffset destination: Int) -> Vault {
        let slots = servers.indices.filter { servers[$0].groupID == groupID }
        let reordered = Self.moving(slots.map { servers[$0] }, fromOffsets: source, toOffset: destination)
        var updated = servers
        for (slot, server) in zip(slots, reordered) { updated[slot] = server }
        return with(servers: updated)
    }

    /// A copy of the server named "<name> copy" (then "copy 2", ...), right after the original in its folder, with
    /// the same address, login, jump hosts and settings but none of the original's kept daemon sessions.
    public func duplicatingServer(_ id: UUID) throws(VaultEditError) -> (vault: Vault, copy: Server) {
        guard let original = servers.first(where: { $0.id == id }) else { throw .unknownServer }
        var copy = original
        copy.id = UUID()
        copy.keptSessions = []
        copy.lastSessionBackend = nil
        let taken = Set(servers.map { $0.name.lowercased() })
        var name = "\(original.name) copy"
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(original.name) copy \(n)"
            n += 1
        }
        copy.name = name
        var added = try addingServer(copy)
        let folder = added.servers(inGroup: copy.groupID)
        if let from = folder.firstIndex(where: { $0.id == copy.id }), let at = folder.firstIndex(where: { $0.id == id }) {
            added = added.movingServers(inGroup: copy.groupID, fromOffsets: IndexSet(integer: from), toOffset: at + 1)
        }
        return (added, copy)
    }

    func checkLinks(of server: Server) throws(VaultEditError) {
        if let groupID = server.groupID, !groups.contains(where: { $0.id == groupID }) { throw .unknownGroup }
        if let credentialID = server.credentialID, !credentials.contains(where: { $0.id == credentialID }) {
            throw .unknownCredential
        }
    }

    /// The server's jump chain against `list`. With `only`, a chain that does not reach that server is not judged
    /// (it was valid before this edit, or was already broken and is not this edit's fault).
    func checkJumps(of server: Server, in list: [Server], only: UUID? = nil) throws(VaultEditError) {
        guard !server.jumpHosts.isEmpty else { return }
        do {
            try JumpChain.validate(server, in: list)
        } catch {
            if let only, !Self.reaches(server, only, in: list, seen: []) { return }
            throw .jumpChain(error)
        }
    }

    private static func reaches(_ server: Server, _ target: UUID, in list: [Server], seen: Set<UUID>) -> Bool {
        guard !seen.contains(server.id) else { return false }
        for case .server(let id) in server.jumpHosts {
            if id == target { return true }
            if let next = list.first(where: { $0.id == id }),
               reaches(next, target, in: list, seen: seen.union([server.id])) { return true }
        }
        return false
    }

    /// `Array.move(fromOffsets:toOffset:)` without SwiftUI: the moved items keep their order and land before the
    /// item that was at `destination`.
    static func moving<T>(_ items: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        let valid = source.filter { items.indices.contains($0) }
        let moved = valid.map { items[$0] }
        let before = items.indices.filter { $0 < destination && !valid.contains($0) }.map { items[$0] }
        let after = items.indices.filter { $0 >= destination && !valid.contains($0) }.map { items[$0] }
        return before + moved + after
    }

    func with(groups: [ServerGroup]? = nil, servers: [Server]? = nil, credentials: [Credential]? = nil,
              remoteDesktops: [RemoteDesktop]? = nil) -> Vault {
        var copy = self
        if let remoteDesktops { copy.remoteDesktops = remoteDesktops }
        if let groups { copy.groups = groups }
        if let servers { copy.servers = servers }
        if let credentials { copy.credentials = credentials }
        return copy
    }
}
