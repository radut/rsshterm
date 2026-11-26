import Foundation

/// A user name and a login the user picked after the server refused one ("Try another login…").
public struct LoginAttempt: Hashable, Sendable {
    public var username: String
    public var login: QuickLogin

    public init(username: String, login: QuickLogin) {
        self.username = username
        self.login = login
    }

    /// "ubuntu + key ops", "ubuntu + password"; "user ubuntu" when the password is asked by the terminal (no secret).
    var summary: String {
        switch login.secret {
        case .password(let password) where password.isEmpty: "user \(username)"
        case .password: login.credentialID == nil ? "\(username) + password" : "\(username) + password \(login.label)"
        case .privateKey: "\(username) + key \(login.label)"
        }
    }
}

/// After a login that worked with another user or login than the saved one: what the app asks once.
public enum LoginSaveOffer: Hashable, Sendable {
    /// A saved server: store the new user and login on it.
    case updateServer(serverID: UUID, serverName: String, attempt: LoginAttempt)
    /// A Quick Connect (unsaved) session: save it as a server.
    case saveServer(attempt: LoginAttempt)

    public var attempt: LoginAttempt {
        switch self {
        case .updateServer(_, _, let attempt), .saveServer(let attempt): attempt
        }
    }

    public var message: String {
        switch self {
        case .updateServer(_, let name, let attempt): "Save \(attempt.summary) for \(name)?"
        case .saveServer(let attempt): "Save this server with \(attempt.summary)?"
        }
    }
}

/// "The server refused the login" -> Try another login… -> the picker -> one attempt -> on success, once, "Save …?".
/// It never retries on its own: a refused attempt goes back to the banner, from where the picker opens again.
/// Shared by the iOS session, the Mac and the Linux panes.
public struct LoginRetryFlow: Hashable, Sendable {
    /// The login the server was saved with; nil for a Quick Connect session.
    public struct SavedLogin: Hashable, Sendable {
        public var serverID: UUID
        public var serverName: String
        public var username: String
        public var credentialID: UUID?

        public init(serverID: UUID, serverName: String, username: String, credentialID: UUID?) {
            self.serverID = serverID
            self.serverName = serverName
            self.username = username
            self.credentialID = credentialID
        }
    }

    public enum Phase: Hashable, Sendable {
        case idle
        /// The failure banner shows "Try another login…" next to Retry.
        case offering(SSHFailure)
        /// The picker is open over that failure.
        case picking(SSHFailure)
        /// Connecting with the picked user and login.
        case trying(LoginAttempt)
        /// It worked and differs from what is saved: ask once.
        case offeringSave(LoginSaveOffer)
    }

    public let saved: SavedLogin?
    public private(set) var phase: Phase = .idle
    /// The last picked attempt, to preselect it when the picker opens again.
    public private(set) var lastAttempt: LoginAttempt?

    public init(saved: SavedLogin?) {
        self.saved = saved
    }

    public var offersOtherLogin: Bool {
        if case .offering = phase { true } else { false }
    }

    public var isPicking: Bool {
        if case .picking = phase { true } else { false }
    }

    public var saveOffer: LoginSaveOffer? {
        if case .offeringSave(let offer) = phase { offer } else { nil }
    }

    /// The connection failed: a refused login offers the picker, anything else (network, host key) does not.
    public mutating func failed(_ failure: SSHFailure) {
        phase = failure.offersOtherLogin ? .offering(failure) : .idle
    }

    public mutating func openPicker() {
        if case .offering(let failure) = phase { phase = .picking(failure) }
    }

    public mutating func closePicker() {
        if case .picking(let failure) = phase { phase = .offering(failure) }
    }

    public mutating func choose(_ attempt: LoginAttempt) {
        lastAttempt = attempt
        phase = .trying(attempt)
    }

    /// Logged in. Only a picked attempt that differs from the saved login asks to be saved.
    public mutating func connected() {
        guard case .trying(let attempt) = phase else { phase = .idle; return }
        guard let saved else { phase = .offeringSave(.saveServer(attempt: attempt)); return }
        let sameLogin = attempt.login.credentialID != nil && attempt.login.credentialID == saved.credentialID
        if attempt.username == saved.username && sameLogin {
            phase = .idle
        } else {
            phase = .offeringSave(.updateServer(serverID: saved.serverID, serverName: saved.serverName, attempt: attempt))
        }
    }

    /// "Not now", or the offer was saved.
    public mutating func dismissSave() {
        if case .offeringSave = phase { phase = .idle }
    }
}

extension SSHFailure {
    /// True when the login itself was refused or unusable, so another user, key or password may work. Network and
    /// host key failures, and a refused jump host (its login is not the one being picked), do not offer it.
    public var offersOtherLogin: Bool {
        switch self {
        case .authenticationFailed, .noCredential, .passphraseRequired, .wrongPassphrase, .unsupportedKey, .invalidKey:
            true
        default:
            false
        }
    }
}

extension Vault {
    /// The server with the user and login of `attempt`: a vault credential is linked, a typed password becomes a new
    /// credential ("ubuntu@host password"), a password the terminal asked for (empty) keeps the server's login.
    public func savingLogin(_ attempt: LoginAttempt, forServer id: UUID) throws(VaultEditError) -> Vault {
        guard var server = servers.first(where: { $0.id == id }) else { throw .unknownServer }
        server.username = attempt.username
        var next = self
        if let credentialID = attempt.login.credentialID, credentials.contains(where: { $0.id == credentialID }) {
            server.credentialID = credentialID
        } else if case .password(let password) = attempt.login.secret, !password.isEmpty {
            let credential = Credential(label: "\(attempt.username)@\(server.host) password", kind: .password(password))
            next = try next.addingCredential(credential)
            server.credentialID = credential.id
        }
        return try next.updatingServer(server)
    }
}
