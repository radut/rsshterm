import Foundation

/// Folder edits. Names are trimmed and unique regardless of case.
extension Vault {
    public func addingGroup(_ group: ServerGroup) throws(VaultEditError) -> Vault {
        guard !groups.contains(where: { $0.id == group.id }) else { throw .duplicateID }
        let name = try checkedGroupName(group.name, excluding: nil)
        return with(groups: groups + [ServerGroup(id: group.id, name: name)])
    }

    public func renamingGroup(_ id: UUID, to newName: String) throws(VaultEditError) -> Vault {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw .unknownGroup }
        var updated = groups
        updated[index].name = try checkedGroupName(newName, excluding: id)
        return with(groups: updated)
    }

    /// Removes the folder; its servers stay, ungrouped.
    public func deletingGroup(_ id: UUID) throws(VaultEditError) -> Vault {
        guard groups.contains(where: { $0.id == id }) else { throw .unknownGroup }
        let freed = servers.map { server in
            var copy = server
            if copy.groupID == id { copy.groupID = nil }
            return copy
        }
        let freedDesktops = remoteDesktops.map { desktop in
            var copy = desktop
            if copy.groupID == id { copy.groupID = nil }
            return copy
        }
        return with(groups: groups.filter { $0.id != id }, servers: freed, remoteDesktops: freedDesktops)
    }

    public func movingGroups(fromOffsets source: IndexSet, toOffset destination: Int) -> Vault {
        with(groups: Self.moving(groups, fromOffsets: source, toOffset: destination))
    }

    private func checkedGroupName(_ raw: String, excluding id: UUID?) throws(VaultEditError) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .emptyName }
        let taken = groups.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard !taken else { throw .groupNameTaken }
        return name
    }
}
