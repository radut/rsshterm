import Foundation

/// How Quick Connect logs in once the hosts and user are known.
public enum QuickLoginChoice: Hashable, Sendable {
    /// The vault's keys that open without a prompt, like ssh's identity files; the user picks another login if none works.
    case automatic
    /// A saved key or password.
    case credential(UUID)
    /// A password typed on the login step (kept in memory unless the user saves it).
    case password
}

/// Quick Connect, step by step: hosts -> user (skipped when every host carries user@) -> login -> connecting.
/// Pure state so it is tested without UI; the screen drives it and turns the result into sessions or servers.
public struct QuickConnectFlow: Hashable, Sendable {
    public enum Step: Hashable, Sendable {
        case hosts, user, login, connecting
    }

    public private(set) var hosts: [QuickHost]
    /// Used for hosts without their own ":port"; empty means 22.
    public var port: String
    /// The user picked on the user step, for hosts without their own "user@".
    public var username: String?
    public var login: QuickLoginChoice?
    /// Optional jump hosts in OpenSSH ProxyJump syntax ("bastion,ops@gw:2222"); empty connects directly.
    public var via: String = ""
    public private(set) var isConnecting = false

    public init(hosts: [QuickHost] = [], port: String = "22", username: String? = nil) {
        self.hosts = hosts
        self.port = port
        self.username = username
    }

    /// Prefilled from "user@host[:port]" typed in the server search.
    public init(address: QuickAddress) {
        self.init(hosts: [QuickHost(username: address.username, host: address.host, port: address.port)])
    }

    public var step: Step {
        if isConnecting { return .connecting }
        if hosts.isEmpty { return .hosts }
        if needsUser && trimmedUser == nil { return .user }
        return .login
    }

    /// True while some host has no "user@" of its own.
    public var needsUser: Bool { hosts.contains { $0.username == nil } }

    // MARK: hosts

    /// Adds the hosts in `text` (one, or a pasted list); returns the tokens that were not hosts.
    @discardableResult
    public mutating func addHosts(_ text: String) -> [String] {
        let parsed = QuickHost.parseList(text)
        hosts += parsed.hosts.filter { !hosts.contains($0) }
        return parsed.invalid
    }

    public mutating func removeHosts(atOffsets offsets: IndexSet) {
        hosts = hosts.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }

    // MARK: user, login, connect

    public mutating func chooseUser(_ user: String) {
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        username = name.isEmpty ? nil : name
    }

    /// One target per host, each validated; the first invalid one throws.
    public func targets() throws(ConnectionTarget.ValidationError) -> [ConnectionTarget] {
        guard !hosts.isEmpty else { throw .emptyHost }
        return try hosts.map { host throws(ConnectionTarget.ValidationError) in
            try host.target(username: trimmedUser, port: port)
        }
    }

    /// Moves to `.connecting` with `login` and returns the targets to open; throws (and stays put) when invalid.
    public mutating func connect(with login: QuickLoginChoice) throws(ConnectionTarget.ValidationError)
        -> [ConnectionTarget] {
        let all = try targets()
        self.login = login
        isConnecting = true
        return all
    }

    /// Why `via` cannot be read, in words for the field; nil when it is empty or fine.
    public var viaProblem: String? {
        do { _ = try ProxyJump.parse(via); return nil } catch { return error.message }
    }

    /// The jump list for `via`: names of saved servers become references to them, anything else an inline hop with
    /// `defaultUsername` and `credentialID` (`ProxyJump.jumpHosts`).
    public func jumpHosts(servers: [Server], defaultUsername: String,
                          credentialID: UUID?) throws(ProxyJumpError) -> [JumpHost] {
        try ProxyJump.jumpHosts(from: via, servers: servers, defaultUsername: defaultUsername, credentialID: credentialID)
    }

    /// Back to the login step (a refused login, or the user went back).
    public mutating func stopConnecting() { isConnecting = false }

    /// One server per host, named after the host, all logging in with `credentialID`, in `groupID`.
    public func serverDrafts(groupID: UUID?, credentialID: UUID?,
                             jumpHosts: [JumpHost] = []) throws(ConnectionTarget.ValidationError) -> [ServerDraft] {
        try targets().map { target in
            var draft = ServerDraft(name: target.host, host: target.host, port: String(target.port),
                                    username: target.username, groupID: groupID, credentialID: credentialID)
            draft.jumpHosts = jumpHosts
            return draft
        }
    }

    private var trimmedUser: String? {
        guard let name = username?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}
