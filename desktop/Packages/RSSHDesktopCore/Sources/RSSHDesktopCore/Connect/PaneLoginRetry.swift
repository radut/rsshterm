import Foundation
import RSSHKit

/// "Try another login…" on one desktop ssh pane: the shared `LoginRetryFlow`, the user and login picked, and what the
/// app must write and run for it. The Mac and the Linux app drive their bar and dialog from it.
public struct PaneLoginRetry: Sendable {
    public enum Choice: Hashable, Sendable {
        case key(UUID)
        /// ssh asks for the password in the terminal.
        case askPassword
    }

    /// A vault key the built-in agent holds, as the picker lists it.
    public struct KeyOption: Hashable, Sendable {
        public var credentialID: UUID
        public var label: String
        public var publicLine: String

        public init(credentialID: UUID, label: String, publicLine: String) {
            self.credentialID = credentialID
            self.label = label
            self.publicLine = publicLine
        }

        public init(_ key: AgentKey) {
            let config = SSHConfigKey(key)
            self.init(credentialID: key.id, label: key.label, publicLine: config.publicLine)
        }
    }

    /// What to start: the override for `ssh`, and the public key file to write first (keys only).
    public struct Launch: Hashable, Sendable {
        public var override: SSHLoginOverride
        public var publicKey: (path: String, content: String)? { keyFile.map { ($0.path, $0.content) } }
        let keyFile: KeyFile?

        struct KeyFile: Hashable, Sendable {
            var path: String
            var content: String
        }
    }

    public private(set) var flow: LoginRetryFlow
    /// The last login started; a plain Retry runs it again.
    public private(set) var override: SSHLoginOverride?

    public init(server: Server) {
        flow = LoginRetryFlow(saved: .init(serverID: server.id, serverName: server.name, username: server.username,
                                           credentialID: server.credentialID))
    }

    /// The server's own user first, then Quick Connect's users.
    public static func users(current: String, quickUsers: [String]) -> [String] {
        var list = [current]
        for user in quickUsers where !list.contains(user) { list.append(user) }
        return list
    }

    /// ssh said "Permission denied".
    public mutating func refused() { flow.failed(.authenticationFailed) }

    /// The picker's choice; nil (nothing changes) for a user ssh cannot take or a key the agent does not hold.
    public mutating func choose(username: String, choice: Choice, keys: [KeyOption], keyDirectory: String,
                                markerDirectory: String) -> Launch? {
        guard let user = SSHLoginOverride.validUsername(username) else { return nil }
        let marker = "\(markerDirectory)/rssh-login-\(UUID().uuidString.lowercased())"
        let launch: Launch
        switch choice {
        case .askPassword:
            launch = Launch(override: SSHLoginOverride(username: user, login: .askPassword, markerFile: marker), keyFile: nil)
        case .key(let id):
            guard let key = keys.first(where: { $0.credentialID == id }) else { return nil }
            let path = "\(keyDirectory)/\(id.uuidString.lowercased()).pub"
            launch = Launch(override: SSHLoginOverride(username: user,
                                                       login: .key(credentialID: id, label: key.label, publicKeyFile: path),
                                                       markerFile: marker),
                            keyFile: .init(path: path, content: key.publicLine + "\n"))
        }
        override = launch.override
        flow.choose(launch.override.attempt)
        return launch
    }

    /// The LocalCommand marker appeared: ssh logged in.
    public mutating func loggedIn() { flow.connected() }

    public mutating func openPicker() { flow.openPicker() }
    public mutating func closePicker() { flow.closePicker() }
    public mutating func dismissSave() { flow.dismissSave() }
}

extension PaneLoginRetry.Launch {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.override == rhs.override && lhs.keyFile == rhs.keyFile }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(override)
        hasher.combine(keyFile)
    }
}
