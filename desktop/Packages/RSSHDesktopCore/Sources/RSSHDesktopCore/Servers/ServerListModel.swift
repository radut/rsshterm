import Foundation
import Observation
import RSSHKit

/// The server sidebar: folders (vault groups, in the user's order) with their servers, "Servers" for the ungrouped
/// ones, a search over name, host, user, folder, tags and notes, a tag filter, the selection, and every list edit
/// (folders, delete, duplicate, drag to a folder, reorder, import from ~/.ssh/config). Edits go through the
/// `VaultDocument`, so they autosave and regenerate the ssh_config include.
@MainActor @Observable
public final class ServerListModel {
    /// One folder of the sidebar; `groupID` nil is the ungrouped "Servers" section, always first.
    public struct Section: Identifiable, Equatable, Sendable {
        public let groupID: UUID?
        public let title: String
        public let servers: [Server]
        public let isCollapsed: Bool

        public var id: String { groupID?.uuidString ?? "ungrouped" }

        public init(groupID: UUID?, title: String, servers: [Server], isCollapsed: Bool) {
            self.groupID = groupID
            self.title = title
            self.servers = servers
            self.isCollapsed = isCollapsed
        }
    }

    public static let ungroupedTitle = "Servers"

    public var query = ""
    /// Only servers with this tag (case ignored); nil shows all.
    public var tagFilter: String?
    public var selection: Set<UUID> = []
    /// The last refused or failed edit, as a sentence; nil after a good one.
    public var error: String?
    public private(set) var collapsed: Set<UUID> = []
    /// Ungrouped servers have no folder to collapse; this is the same switch for their section.
    public private(set) var ungroupedCollapsed = false

    @ObservationIgnored public let document: any VaultDocument

    public init(document: any VaultDocument) { self.document = document }

    public var vault: Vault { document.vault }

    /// The sections to show. While searching or filtering, empty sections are left out and collapsed ones open.
    public var sections: [Section] {
        let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty || tagFilter != nil
        let visible = Set(matchingServers.map(\.id))
        let ungrouped = vault.servers(inGroup: nil).filter { visible.contains($0.id) }
        var out: [Section] = []
        if !ungrouped.isEmpty || !filtering {
            out.append(Section(groupID: nil, title: Self.ungroupedTitle, servers: ungrouped,
                               isCollapsed: !filtering && ungroupedCollapsed))
        }
        for group in vault.groups {
            let servers = vault.servers(inGroup: group.id).filter { visible.contains($0.id) }
            if filtering && servers.isEmpty { continue }
            out.append(Section(groupID: group.id, title: group.name, servers: servers,
                               isCollapsed: !filtering && collapsed.contains(group.id)))
        }
        return out
    }

    /// Servers in sidebar order (sections top to bottom), as the keyboard walks them; collapsed sections skipped.
    public var visibleServers: [Server] { sections.filter { !$0.isCollapsed }.flatMap(\.servers) }

    /// Every tag in use, sorted, each spelled as first saved.
    public var allTags: [String] {
        var seen: [String: String] = [:]
        for tag in vault.servers.flatMap(\.tags) where seen[tag.lowercased()] == nil { seen[tag.lowercased()] = tag }
        return seen.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public var selectedServers: [Server] { vault.servers.filter { selection.contains($0.id) } }

    public func groupName(_ id: UUID?) -> String {
        id.flatMap { id in vault.groups.first { $0.id == id }?.name } ?? Self.ungroupedTitle
    }

    // MARK: folders

    public func toggleCollapsed(_ groupID: UUID?) {
        guard let groupID else { ungroupedCollapsed.toggle(); return }
        if collapsed.contains(groupID) { collapsed.remove(groupID) } else { collapsed.insert(groupID) }
    }

    /// The new folder's id, or nil (empty or taken name) with `error` set.
    @discardableResult
    public func addGroup(named name: String) async -> UUID? {
        let group = ServerGroup(name: name)
        return await edit { vault throws(VaultEditError) in try vault.addingGroup(group) } == nil ? nil : group.id
    }

    @discardableResult
    public func renameGroup(_ id: UUID, to name: String) async -> Bool {
        await edit { vault throws(VaultEditError) in try vault.renamingGroup(id, to: name) } != nil
    }

    /// Removes the folder; its servers move to "Servers".
    @discardableResult
    public func deleteGroup(_ id: UUID) async -> Bool {
        collapsed.remove(id)
        return await edit { vault throws(VaultEditError) in try vault.deletingGroup(id) } != nil
    }

    public func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) async {
        _ = await edit { vault in vault.movingGroups(fromOffsets: source, toOffset: destination) }
    }

    // MARK: servers

    @discardableResult
    public func delete(_ ids: Set<UUID>) async -> Bool {
        guard await edit({ vault throws(VaultEditError) in try vault.deletingServers(ids) }) != nil else { return false }
        selection.subtract(ids)
        return true
    }

    /// A copy named "<name> copy" (then "copy 2" ...), in the same folder right after the original, with the same
    /// login and settings but no kept daemon sessions (`Vault.duplicatingServer`). Selects and returns it.
    @discardableResult
    public func duplicate(_ id: UUID) async -> Server? {
        var copy: Server?
        let saved = await edit { vault throws(VaultEditError) in
            let result = try vault.duplicatingServer(id)
            copy = result.copy
            return result.vault
        }
        guard saved != nil, let copy else { return nil }
        selection = [copy.id]
        return copy
    }

    /// Drag and drop onto a folder (nil: "Servers"); servers keep their relative order and go to the end.
    @discardableResult
    public func move(_ ids: [UUID], toGroup groupID: UUID?) async -> Bool {
        await edit { vault throws(VaultEditError) in
            var moved = vault
            for id in ids where moved.servers.contains(where: { $0.id == id }) {
                moved = try moved.movingServer(id, toGroup: groupID)
                // movingServer keeps the vault position: move it to the end of the target folder.
                let folder = moved.servers(inGroup: groupID)
                if let from = folder.firstIndex(where: { $0.id == id }) {
                    moved = moved.movingServers(inGroup: groupID, fromOffsets: IndexSet(integer: from),
                                                toOffset: folder.count)
                }
            }
            return moved
        } != nil
    }

    /// Reorder within one folder (offsets as the section lists them).
    public func reorder(inGroup groupID: UUID?, fromOffsets source: IndexSet, toOffset destination: Int) async {
        _ = await edit { vault in vault.movingServers(inGroup: groupID, fromOffsets: source, toOffset: destination) }
    }

    // MARK: keyboard selection

    /// Down/up arrow: the next or previous visible server becomes the only selection (wraps at the ends).
    public func selectNext(_ forward: Bool = true) {
        let list = visibleServers
        guard !list.isEmpty else { selection = []; return }
        let current = list.firstIndex { selection.contains($0.id) }
        let next = current.map { (forward ? $0 + 1 : $0 - 1 + list.count) % list.count } ?? (forward ? 0 : list.count - 1)
        selection = [list[next].id]
    }

    // MARK: editors

    public func editorForNewServer(inGroup groupID: UUID? = nil) -> ServerEditorModel {
        ServerEditorModel(document: document, groupID: groupID)
    }

    public func editor(for id: UUID) -> ServerEditorModel? {
        guard let server = vault.servers.first(where: { $0.id == id }) else { return nil }
        return ServerEditorModel(document: document, server: server)
    }

    // MARK: import

    /// The import sheet's rows for an ssh_config text (~/.ssh/config).
    public func importCandidates(sshConfig text: String, defaultUser: String?) -> (candidates: [SSHConfigImportCandidate],
                                                                                   result: SSHConfigParseResult) {
        let result = SSHConfigParser.parse(text)
        return (SSHConfigImport.candidates(result, vault: vault, defaultUser: defaultUser), result)
    }

    /// Adds the chosen candidates (importable, not already saved) to `destination`; returns how many were added.
    /// `credentialFor` maps an entry's first IdentityFile to a vault key the app imported (nil: no login).
    @discardableResult
    public func importServers(_ candidates: [SSHConfigImportCandidate], to destination: ScanDestination,
                              credentialFor: (SSHConfigEntry) -> UUID? = { _ in nil }) async -> Int {
        var added = 0
        let saved = await edit { vault throws(VaultEditError) in
            var out = vault
            let groupID = try VaultEdits.resolve(destination, in: &out)
            var importedIDs: [String: UUID] = [:]
            var pendingJumps: [(UUID, SSHConfigEntry)] = []
            for candidate in candidates where candidate.isImportable && candidate.existing == nil {
                var draft = candidate.draft
                draft.groupID = groupID
                draft.credentialID = credentialFor(candidate.entry)
                if candidate.entry.forwardAgent == true {
                    draft.agentForwarding = ServerAgentSettings(forward: .on)
                }
                guard let server = try? draft.makeServer(id: UUID()) else { continue }
                out = try out.addingServer(server)
                importedIDs[candidate.entry.alias.lowercased()] = server.id
                if candidate.entry.proxyJump != nil { pendingJumps.append((server.id, candidate.entry)) }
                added += 1
            }
            // ProxyJump after every server exists, so hops can name servers imported in the same batch.
            for (id, entry) in pendingJumps {
                guard var server = out.servers.first(where: { $0.id == id }) else { continue }
                server.jumpHosts = SSHConfigImport.jumpHosts(entry, vault: out, imported: importedIDs)
                if (try? JumpChain.validate(server, in: out.servers.map { $0.id == id ? server : $0 })) != nil {
                    out = try out.updatingServer(server)
                }
            }
            return out
        }
        return saved == nil ? 0 : added
    }

    // MARK: private

    private var matchingServers: [Server] {
        let found = vault.searchingServers(query)
        guard let tag = tagFilter else { return found }
        return found.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    private func edit(_ change: (Vault) throws(VaultEditError) -> Vault) async -> Vault? {
        await commitEdit(change)
    }

    /// Runs a vault edit through the document and keeps its error for the UI.
    private func commitEdit(_ change: (Vault) throws(VaultEditError) -> Vault) async -> Vault? {
        let outcome = await VaultEdits.apply(document, change)
        error = outcome.error
        return outcome.vault
    }
}
