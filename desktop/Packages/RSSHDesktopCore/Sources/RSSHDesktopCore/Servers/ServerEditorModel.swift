import Foundation
import Observation
import RSSHKit

/// The server editor (new server or edit): every field of `ServerDraft`, validated as typed, the login picked from
/// the vault (or a new password typed here), and `save()` writing the server through the `VaultDocument` (autosave,
/// ssh_config regenerated). Errors under each field show after the first save attempt.
@MainActor @Observable
public final class ServerEditorModel {
    /// The login rows of the editor: none, a saved password or key, or a new password typed here.
    public enum Login: Hashable, Sendable {
        case none
        case saved(UUID)
        /// Saved as a new password credential named after the server on save.
        case newPassword
    }

    public let serverID: UUID
    public let isNew: Bool
    public var draft: ServerDraft
    public var login: Login
    /// The password typed for `.newPassword`; never stored anywhere but the vault.
    public var newPassword = ""
    /// The screens this server opens as besides (or instead of) SSH (`draft.sshEnabled`). New servers: SSH only.
    public var screens: Set<ScreenService> = []
    /// Set by the first `save()`, so field errors do not shout while the user is still typing.
    public private(set) var showsErrors = false
    /// A refused or failed save, as a sentence.
    public private(set) var error: String?
    public private(set) var isSaving = false

    @ObservationIgnored public let document: any VaultDocument
    @ObservationIgnored private let original: ServerDraft
    @ObservationIgnored private var originalScreens: Set<ScreenService> = []

    public init(document: any VaultDocument, groupID: UUID? = nil) {
        self.document = document
        serverID = UUID()
        isNew = true
        let draft = ServerDraft(groupID: groupID)
        self.draft = draft
        login = .none
        original = draft
    }

    public init(document: any VaultDocument, server: Server) {
        self.document = document
        serverID = server.id
        isNew = false
        let draft = ServerDraft(server: server)
        self.draft = draft
        login = server.credentialID.map(Login.saved) ?? .none
        let services = Set(document.vault.services(of: server.id).map { ScreenService($0.kind) })
        screens = services
        originalScreens = services
        original = draft
    }

    // MARK: what the form shows

    public var title: String { isNew ? "New Server" : (draft.name.isEmpty ? draft.host : draft.name) }
    public var groups: [ServerGroup] { document.vault.groups }
    public var passwords: [Credential] { document.vault.credentials(for: .password) }
    public var keys: [Credential] { document.vault.credentials(for: .key) }
    public var themes: [TerminalColorScheme] { TerminalColorSchemes.all }
    public var fonts: [TerminalFontFamily] { TerminalFontCatalog.families }
    public var fontSizes: ClosedRange<Int> { TerminalPreferences.fontSizeRange }
    public var sessionBackends: [SessionBackend] { SessionBackend.allCases }

    /// The fields that are wrong now, in form order.
    public var issues: [ServerDraft.Field] { draft.issues }

    /// The message under `field`, once errors show.
    public func message(for field: ServerDraft.Field) -> String? {
        showsErrors && draft.issues.contains(field) ? field.message : nil
    }

    /// The new-password row's message, once errors show.
    public var passwordMessage: String? {
        showsErrors && login == .newPassword && newPassword.isEmpty ? VaultEditError.emptySecret.errorDescription : nil
    }

    /// Why the services cannot be saved: none is on.
    public var servicesMessage: String? {
        draft.sshEnabled || !screens.isEmpty ? nil : VaultEditError.noService.errorDescription
    }

    /// Screens that reach their host through this server's SSH, when the edit turns SSH off: the UI warns and offers
    /// to switch them to direct (`save(screensGoDirect:)`), never leaving them broken unasked.
    public var screensLosingSSH: [RemoteDesktop] {
        guard !isNew, original.sshEnabled, !draft.sshEnabled else { return [] }
        return document.vault.screensRelyingOnSSH(of: serverID)
    }

    /// Saved servers with this host, when a new server would bring a screen: the UI asks "Add RDP to <server>" or
    /// "Keep as a separate server" before saving (never merged without asking).
    public var sameHostServers: [Server] {
        guard isNew, !screens.isEmpty else { return [] }
        return document.vault.servers(matchingHost: draft.host).filter { $0.id != serverID }
    }

    /// "Add RDP to <server>": the ticked screens become services of that saved server instead of a new server.
    public func addScreens(to serverID: UUID) async -> Bool {
        guard let server = document.vault.servers.first(where: { $0.id == serverID }) else { return false }
        let have = Set(document.vault.services(of: serverID).map { ScreenService($0.kind) })
        do {
            let next = try document.vault.settingServices(of: serverID, ssh: server.sshEnabled, screens: have.union(screens))
            try await document.commit(next)
            error = nil
            return true
        } catch let refusal as VaultEditError {
            error = VaultEdits.errorMessage(refusal)
        } catch {
            self.error = error.localizedDescription
        }
        return false
    }

    public var canSave: Bool {
        servicesMessage == nil && draft.issues.isEmpty && !(login == .newPassword && newPassword.isEmpty) && !isSaving && chainError == nil
    }

    private var chainError: JumpChainError? {
        guard !draft.jumpHosts.isEmpty, let server = try? draft.makeServer(id: serverID) else { return nil }
        do { try JumpChain.validate(server, in: document.vault.servers.filter { $0.id != serverID } + [server]) } catch {
            return error
        }
        return nil
    }
    public var hasChanges: Bool {
        draft != original || login != (original.credentialID.map(Login.saved) ?? .none) || screens != originalScreens
    }

    /// Tags as one comma-separated field.
    public var tagsText: String {
        get { draft.tags.joined(separator: ", ") }
        set { draft.tags = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    /// Agent forwarding of this server, Default/On/Off as the editor's picker shows it.
    public var forwardAgent: AgentSwitch {
        get { draft.agentForwarding?.forward ?? .default }
        set {
            var settings = draft.agentForwarding ?? ServerAgentSettings()
            settings.forward = newValue
            draft.agentForwarding = settings
        }
    }

    // MARK: jump through (ProxyJump)

    /// Saved servers this one can jump through (not itself).
    public var jumpCandidates: [Server] { document.vault.servers.filter { $0.id != serverID } }

    /// Each hop as the list shows it: a server's name, or user@host[:port] for an inline hop.
    public var jumpTitles: [String] {
        draft.jumpHosts.map { jump in
            switch jump {
            case .server(let id): document.vault.servers.first { $0.id == id }?.name ?? "(deleted server)"
            case .inline(let hop): hop.displayName
            }
        }
    }

    public func addJump(server id: UUID) {
        guard id != serverID, !draft.jumpHosts.contains(.server(id)) else { return }
        draft.jumpHosts.append(.server(id))
    }

    /// Adds "user@host[:port]" typed in the list; false when it is not such an address.
    @discardableResult
    public func addJump(address text: String, credentialID: UUID? = nil) -> Bool {
        guard let address = QuickAddress.parse(text) else { return false }
        draft.jumpHosts.append(.inline(InlineJumpHost(host: address.host, port: address.port ?? 22,
                                                      username: address.username, credentialID: credentialID)))
        return true
    }

    public func removeJumps(atOffsets offsets: IndexSet) {
        draft.jumpHosts = draft.jumpHosts.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }

    public func moveJumps(fromOffsets source: IndexSet, toOffset destination: Int) {
        let hops = draft.jumpHosts
        let moved = source.filter { hops.indices.contains($0) }.map { hops[$0] }
        let before = hops.indices.filter { $0 < destination && !source.contains($0) }.map { hops[$0] }
        let after = hops.indices.filter { $0 >= destination && !source.contains($0) }.map { hops[$0] }
        draft.jumpHosts = before + moved + after
    }

    /// Why the chain cannot be followed (a loop through other servers, too deep), once errors show.
    public var jumpMessage: String? {
        guard showsErrors, let server = try? draft.makeServer(id: serverID) else { return nil }
        let others = document.vault.servers.filter { $0.id != serverID } + [server]
        do { try JumpChain.validate(server, in: others) } catch { return error.message }
        return nil
    }

    // MARK: save

    /// Validates, saves and returns the server; nil (with the field errors or `error` shown) when it could not.
    @discardableResult
    public func save(screensGoDirect: Bool = false) async -> Server? {
        showsErrors = true
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }

        var vault = document.vault
        var draft = self.draft
        do {
            switch login {
            case .none: draft.credentialID = nil
            case .saved(let id): draft.credentialID = id
            case .newPassword:
                let label = draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? draft.host : draft.name
                let credential = Credential(label: "\(label) password", kind: .password(newPassword))
                vault = try vault.addingCredential(credential)
                draft.credentialID = credential.id
            }
            let server = try draft.makeServer(id: serverID)
            vault = isNew ? try vault.addingServer(server) : try vault.updatingServer(server)
            vault = try vault.settingServices(of: serverID, ssh: server.sshEnabled, screens: screens)
            if screensGoDirect { vault = try vault.switchingScreensToDirect(of: serverID) }
            do { try await document.commit(vault) } catch {
                self.error = "Changed here, but not stored: \(error.localizedDescription)"
                return server
            }
            error = nil
            if case .newPassword = login {
                login = .saved(draft.credentialID!)
                newPassword = ""
            }
            self.draft = draft
            return server
        } catch let refusal as VaultEditError {
            error = VaultEdits.errorMessage(refusal)
        } catch let invalid as ServerDraftError {
            error = invalid.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
        return nil
    }
}
