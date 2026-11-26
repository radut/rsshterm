import Foundation

/// The login a screen is opened with. The password comes out of the vault (or the sheet) at connect time.
public struct RemoteDesktopLogin: Sendable, Equatable {
    public var username: String?
    public var password: String

    public init(username: String?, password: String) {
        self.username = username
        self.password = password
    }
}

/// What the login sheet shows: the user to fill in and the vault passwords to pick from.
public struct RemoteDesktopLoginSheet: Sendable, Equatable {
    public var username: String
    /// Mac and Windows accounts need a user; a VNC password does not.
    public var needsUsername: Bool
    /// Password credentials only, in vault order (an SSH key cannot open a screen).
    public var savedPasswords: [Credential]
    public var preselected: UUID?
    /// Why the sheet is back (a failed login); nil the first time.
    public var error: String?
}

/// "Connect" pressed on a remote desktop: what happens next, decided from the entry and the vault alone, so every
/// platform's UI follows the same flow (docs/research/remote-desktop/design.md).
public enum RemoteDesktopConnectPlan: Sendable, Equatable {
    public enum DirectRisk: Sendable, Equatable {
        /// VNC without SSH: the password challenge and every frame cross the network in the clear.
        case notEncrypted
        /// RDP without SSH: encrypted, but the RDP port must be reachable from here.
        case exposedPort
    }

    case confirmDirect(DirectRisk)
    case connect(RemoteDesktopLogin)
    case askLogin(RemoteDesktopLoginSheet)

    public static func start(_ desktop: RemoteDesktop, in vault: Vault, directConfirmed: Bool = false)
        -> RemoteDesktopConnectPlan {
        if desktop.transport == .direct, !directConfirmed {
            return .confirmDirect(desktop.kind == .rdp ? .exposedPort : .notEncrypted)
        }
        if !desktop.askEveryTime, let login = savedLogin(desktop, in: vault) { return .connect(login) }
        return .askLogin(loginSheet(desktop, in: vault, error: nil))
    }

    /// The server refused the login: the sheet again, with the reason, the same password preselected.
    public static func afterAuthFailure(_ desktop: RemoteDesktop, in vault: Vault, reason: String?)
        -> RemoteDesktopConnectPlan {
        let who = [desktop.kind.usesUsername ? desktop.username : nil].compactMap { $0 }.first.map { "\($0)@" } ?? ""
        let message = "Wrong password for \(who)\(desktop.name)." + (reason.map { " \($0)" } ?? "")
        return .askLogin(loginSheet(desktop, in: vault, error: message))
    }

    // MARK: the sheet's answer

    public enum SheetChoice: Sendable, Equatable {
        case saved(UUID, username: String?)
        case typed(username: String?, password: String, save: Bool)
        /// Connect with no login: the remote side shows its own (Windows logon, macOS login window, VNC prompt).
        case withoutLogin
    }

    public struct Resolution: Sendable, Equatable {
        public var login: RemoteDesktopLogin?
        /// A typed password to keep, written by `Vault.savingRemoteDesktopLogin` once the login worked.
        public var saveOnSuccess: Credential?
    }

    public static func resolve(_ choice: SheetChoice, for desktop: RemoteDesktop, in vault: Vault) -> Resolution {
        let user: (String?) -> String? = { desktop.kind.usesUsername ? ($0?.isEmpty == false ? $0 : nil) : nil }
        switch choice {
        case .withoutLogin:
            return Resolution(login: nil, saveOnSuccess: nil)
        case .saved(let id, let username):
            guard let credential = vault.credentials.first(where: { $0.id == id }),
                  case .password(let password) = credential.kind else { return Resolution(login: nil, saveOnSuccess: nil) }
            return Resolution(login: RemoteDesktopLogin(username: user(username), password: password), saveOnSuccess: nil)
        case .typed(let username, let password, let save):
            let login = RemoteDesktopLogin(username: user(username), password: password)
            guard save, !password.isEmpty else { return Resolution(login: login, saveOnSuccess: nil) }
            let label = [login.username, desktop.name].compactMap { $0 }.joined(separator: "@")
            return Resolution(login: login, saveOnSuccess: Credential(label: label, kind: .password(password)))
        }
    }

    // MARK: helpers

    static func savedLogin(_ desktop: RemoteDesktop, in vault: Vault) -> RemoteDesktopLogin? {
        guard let id = desktop.credentialID, let credential = vault.credentials.first(where: { $0.id == id }),
              case .password(let password) = credential.kind, !password.isEmpty else { return nil }
        let user = desktop.kind.usesUsername ? desktop.username : nil
        // A Mac or Windows account without a user cannot log in: ask.
        if desktop.kind.usesUsername, (user ?? "").isEmpty { return nil }
        return RemoteDesktopLogin(username: user, password: password)
    }

    /// The sheet for `desktop`; `error` says why it shows (nil the first time).
    public static func loginSheet(_ desktop: RemoteDesktop, in vault: Vault, error: String?) -> RemoteDesktopLoginSheet {
        let passwords = vault.credentials.filter { if case .password = $0.kind { true } else { false } }
        return RemoteDesktopLoginSheet(username: desktop.username ?? "", needsUsername: desktop.kind.usesUsername,
                                       savedPasswords: passwords, preselected: desktop.credentialID, error: error)
    }
}

extension RemoteDesktop {
    /// "Copy from SSH": the tunnel server's user, and its password credential when it logs in with one (the same
    /// vault item). A server that logs in with a key gives only its user.
    public func copyingLogin(from serverID: UUID, in vault: Vault) throws(VaultEditError) -> RemoteDesktop {
        guard let server = vault.servers.first(where: { $0.id == serverID }) else { throw .unknownServer }
        var copy = self
        copy.username = server.username
        if let id = server.credentialID, let credential = vault.credentials.first(where: { $0.id == id }),
           case .password = credential.kind {
            copy.credentialID = id
        }
        return copy
    }
}

extension Vault {
    /// After a typed login worked with "Save to vault": the password becomes a credential and the entry uses it.
    public func savingRemoteDesktopLogin(_ credential: Credential, username: String?, for desktopID: UUID)
        throws(VaultEditError) -> Vault {
        guard var desktop = remoteDesktops.first(where: { $0.id == desktopID }) else { throw .unknownRemoteDesktop }
        let withCredential = try addingCredential(credential)
        desktop.credentialID = credential.id
        if desktop.kind.usesUsername, let username, !username.isEmpty { desktop.username = username }
        return try withCredential.updatingRemoteDesktop(desktop)
    }
}
