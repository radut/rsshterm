import Foundation
import Observation
import RSSHKit

/// One host Quick Connect opens: where, and the logins to try in order (a session moves to the next while the
/// failure `triesNextLogin`).
public struct QuickConnectPlan: Equatable, Sendable {
    public let target: ConnectionTarget
    public let logins: [QuickLogin]

    public init(target: ConnectionTarget, logins: [QuickLogin]) {
        self.target = target
        self.logins = logins
    }
}

/// Quick Connect on the desktop (the host-search field's "Connect to user@host" row and the Quick Connect sheet):
/// hosts (one or a pasted list) -> user (skipped when every host has user@) -> login (automatic vault keys, a
/// saved credential, or a password typed once) -> one tab per host; then "Save" puts the hosts in the vault
/// (Servers, a folder, or a new folder), with the password saved when the user asks. Same steps as iOS.
@MainActor @Observable
public final class QuickConnectModel {
    public private(set) var flow: QuickConnectFlow
    /// The users offered on the user step (Settings' list, last used first).
    public var users: [String]
    /// The password typed on the login step for `.password`.
    public var password = ""
    /// "Save": the new servers open as SSH (default) and/or these screens (RDP, VNC).
    public var sshEnabled = true
    public var screens: Set<ScreenService> = []
    /// Field text of the hosts step.
    public var hostsText = ""
    /// Tokens of the last `addHosts` that were not hosts.
    public private(set) var invalidTokens: [String] = []
    public private(set) var error: String?

    @ObservationIgnored public let document: any VaultDocument

    public init(document: any VaultDocument, users: [String] = TerminalPreferences.defaultQuickConnectUsers,
                address: QuickAddress? = nil) {
        self.document = document
        self.users = users
        flow = address.map(QuickConnectFlow.init(address:)) ?? QuickConnectFlow()
    }

    public var step: QuickConnectFlow.Step { flow.step }
    public var hosts: [QuickHost] { flow.hosts }

    /// Saved logins for the login step: keys first, then passwords.
    public var savedLogins: [Credential] {
        document.vault.credentials(for: .key) + document.vault.credentials(for: .password)
    }

    /// Keys "Automatic" would try, for the hint under it.
    public var automaticLogins: [QuickLogin] { QuickLogin.automatic(from: document.vault.credentials) }

    /// Adds what is in `hostsText` (or `text`), clears the field, and keeps the tokens that were not hosts.
    public func addHosts(_ text: String? = nil) {
        invalidTokens = flow.addHosts(text ?? hostsText)
        if text == nil { hostsText = "" }
    }

    public func removeHosts(atOffsets offsets: IndexSet) { flow.removeHosts(atOffsets: offsets) }

    public var port: String {
        get { flow.port }
        set { flow.port = newValue }
    }

    public func chooseUser(_ user: String) { flow.chooseUser(user) }

    /// The tabs to open, one per host, with the logins of `choice`; nil (with `error`) when a host is invalid or
    /// there is nothing to log in with.
    public func connect(with choice: QuickLoginChoice) -> [QuickConnectPlan]? {
        let logins: [QuickLogin]
        switch choice {
        case .automatic:
            logins = automaticLogins
        case .credential(let id):
            guard let credential = document.vault.credentials.first(where: { $0.id == id }) else {
                error = VaultEdits.errorMessage(.unknownCredential)
                return nil
            }
            logins = [QuickLogin(credential: credential)]
        case .password:
            guard !password.isEmpty else {
                error = VaultEditError.emptySecret.errorDescription
                return nil
            }
            logins = [QuickLogin(label: "Password", secret: .password(password))]
        }
        guard !logins.isEmpty else {
            error = SSHFailure.noCredential.message
            return nil
        }
        do {
            let targets = try flow.connect(with: choice)
            error = nil
            return targets.map { QuickConnectPlan(target: $0, logins: logins) }
        } catch {
            self.error = error.message
            return nil
        }
    }

    /// A refused login, or "Back": the login step again.
    public func stopConnecting() { flow.stopConnecting() }

    /// Saved servers with a host typed here, when a screen is ticked: "Save" asks whether the screens join them.
    public var savedServersForScreens: [Server] {
        guard !screens.isEmpty else { return [] }
        var found: [Server] = []
        for host in flow.hosts {
            for server in document.vault.servers(matchingHost: host.host) where !found.contains(server) { found.append(server) }
        }
        return found
    }

    /// Saves the hosts as servers into `destination`, as SSH and/or the ticked screens (`sshEnabled`, `screens`).
    /// The login that worked (`credentialID`) is linked; a typed password is saved as a credential first when
    /// `savePassword` is on. Returns the new servers (screens that joined a saved server add none).
    @discardableResult
    public func save(to destination: ScanDestination, credentialID: UUID? = nil, savePassword: Bool = false,
                     screensJoinSavedServers: Bool = false) async -> [Server] {
        guard sshEnabled || !screens.isEmpty else {
            error = VaultEditError.noService.errorDescription
            return []
        }
        do { _ = try flow.targets() } catch {
            self.error = error.message
            return []
        }
        var saved: [Server] = []
        let typed = password
        let result = await commitEdit { vault throws(VaultEditError) in
            var out = vault
            var loginID = credentialID
            if savePassword, loginID == nil, !typed.isEmpty {
                let name = flow.hosts.count == 1 ? flow.hosts[0].host : "Quick Connect"
                let credential = Credential(label: "\(name) password", kind: .password(typed))
                out = try out.addingCredential(credential)
                loginID = credential.id
            }
            let groupID = try VaultEdits.resolve(destination, in: &out)
            for var draft in (try? flow.serverDrafts(groupID: groupID, credentialID: loginID)) ?? [] {
                draft.sshEnabled = sshEnabled
                guard let server = try? draft.makeServer(id: UUID()) else { continue }
                let joins = screensJoinSavedServers && !screens.isEmpty && !out.servers(matchingHost: server.host).isEmpty
                if !joins, out.servers.contains(where: { QuickAddress(username: server.username, host: server.host, port: server.port).matches($0) }) {
                    continue
                }
                let result = try out.addingServer(server, screens: screens, screensJoinSavedServers: screensJoinSavedServers)
                out = result.vault
                if let added = result.added { saved.append(added) }
            }
            return out
        }
        return result == nil ? [] : saved
    }

    /// Runs a vault edit through the document and keeps its error for the UI.
    private func commitEdit(_ change: (Vault) throws(VaultEditError) -> Vault) async -> Vault? {
        let outcome = await VaultEdits.apply(document, change)
        error = outcome.error
        return outcome.vault
    }
}
