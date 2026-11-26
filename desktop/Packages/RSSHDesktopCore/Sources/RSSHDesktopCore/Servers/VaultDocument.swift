import Foundation
import Observation
import RSSHKit

/// The unlocked vault as the desktop's view models see it: read `vault`, write with `commit`. The app's document
/// keeps the vault in memory, saves it (autosave to the device file and Google Drive) and regenerates
/// ~/.config/rssh/ssh_config and the agent's keys after every commit (`SSHConfigRefresh`).
@MainActor
public protocol VaultDocument: AnyObject, Observable {
    var vault: Vault { get }
    /// Shows `vault` at once and persists it. Throws when the save failed; the document then keeps the new vault in
    /// memory (so nothing typed is lost) and the caller shows the error.
    func commit(_ vault: Vault) async throws
}

/// A `VaultDocument` that hands every commit to `save` and then to each `afterSave` hook (ssh_config, agent keys).
@MainActor @Observable
public final class SavingVaultDocument: VaultDocument {
    public private(set) var vault: Vault
    /// The error of the last failed save, nil after a good one.
    public private(set) var lastSaveError: String?
    @ObservationIgnored private let save: @MainActor (Vault) async throws -> Void
    @ObservationIgnored private var afterSave: [@MainActor (Vault) -> Void]

    public init(vault: Vault, save: @escaping @MainActor (Vault) async throws -> Void = { _ in },
                afterSave: [@MainActor (Vault) -> Void] = []) {
        self.vault = vault
        self.save = save
        self.afterSave = afterSave
    }

    public func addAfterSave(_ hook: @escaping @MainActor (Vault) -> Void) { afterSave.append(hook) }

    public func commit(_ vault: Vault) async throws {
        self.vault = vault
        do {
            try await save(vault)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
            throw error
        }
        for hook in afterSave { hook(vault) }
    }

    /// Replaces the vault without saving (another device's newer revision arrived).
    public func replace(with vault: Vault) { self.vault = vault }
}

/// Regenerates the ssh_config include and the public key files from the vault (so `ssh <server>` in a local tab
/// keeps matching the vault), as an after-save hook of the document.
public enum SSHConfigRefresh {
    /// The files for `vault`: every private key that can be read becomes an IdentityFile.
    public static func files(for vault: Vault, agentSocket: String, writer: SSHConfigWriter) -> SSHConfigFiles {
        let keys = DesktopAgentKeys.load(vault.credentials).keys.map(SSHConfigKey.init)
        return SSHConfigGenerator.generate(servers: vault.servers, keys: keys, agentSocket: agentSocket,
                                           keyDirectory: writer.keyDirectory)
    }

    /// A hook that writes the files; failures go to `onError` (the app shows them, the save itself succeeded).
    public static func hook(agentSocket: String, writer: SSHConfigWriter,
                            onError: @escaping @MainActor (Error) -> Void = { _ in }) -> @MainActor (Vault) -> Void {
        { vault in
            do { try writer.write(files(for: vault, agentSocket: agentSocket, writer: writer)) } catch { onError(error) }
        }
    }
}

/// Runs vault edits against a document: the edit, then the commit, with the error as a message.
@MainActor
enum VaultEdits {
    /// The edited vault (also when only the save failed: the document shows it, and `error` says it was not
    /// stored); vault nil when the edit was refused.
    static func apply(_ document: any VaultDocument,
                      _ edit: (Vault) throws(VaultEditError) -> Vault) async -> (vault: Vault?, error: String?) {
        let edited: Vault
        do { edited = try edit(document.vault) } catch { return (nil, errorMessage(error)) }
        do {
            try await document.commit(edited)
            return (edited, nil)
        } catch {
            return (edited, "Changed here, but not stored: \(error.localizedDescription)")
        }
    }

    static func errorMessage(_ error: VaultEditError) -> String { error.errorDescription ?? "The change was refused." }

    /// The folder `destination` names, creating a new one (or reusing one of the same name, case ignored).
    static func resolve(_ destination: ScanDestination, in vault: inout Vault) throws(VaultEditError) -> UUID? {
        switch destination {
        case .ungrouped: return nil
        case .folder(let id):
            guard vault.groups.contains(where: { $0.id == id }) else { throw .unknownGroup }
            return id
        case .newFolder(let raw):
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = vault.groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return existing.id
            }
            let group = ServerGroup(name: name)
            vault = try vault.addingGroup(group)
            return group.id
        }
    }
}
