import Foundation

/// One SSH destination. Secrets are never stored here: `credentialID` points into the encrypted `Vault`.
public struct Server: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var credentialID: UUID?
    public var groupID: UUID?
    /// `TerminalColorScheme.id` for this server's terminal; nil uses the default theme from Settings.
    public var themeID: String?
    /// Where this server's sessions live (Settings › Sessions has the default); nil uses that default.
    public var sessionDaemon: SessionBackend?
    /// The backend the daemon last ran a session in here ("tmux"), shown on the server status sheet.
    public var lastSessionBackend: String?
    /// What connecting does when the server has sessions not open here; nil means `.ask`.
    public var resumeChoice: ResumeChoice?
    /// The rsshd sessions kept on this server, so they can be found again after the app lost its tabs.
    public var keptSessions: [KeptSession] = []
    /// Agent forwarding rows of the server editor; nil (older vaults) follows Settings with this server's key.
    public var agentForwarding: ServerAgentSettings?
    /// The hosts a connection goes through first, in order (OpenSSH ProxyJump); empty connects directly.
    public var jumpHosts: [JumpHost] = []
    /// Free labels ("prod", "eu"), unique regardless of case; the server search matches them.
    public var tags: [String] = []
    /// The user's own notes about the server; the server search matches them.
    public var notes: String?
    /// `TerminalFontFamily.name` for this server's terminal; nil uses the font from Settings.
    public var fontFamily: String?
    /// Points, inside `TerminalPreferences.fontSizeRange`; nil uses the size from Settings.
    public var fontSize: Int?
    /// False for a server opened only as a screen (RDP or VNC, `Vault.services(of:)`); older vaults are all SSH.
    /// Written only when false, so an SSH server's entry stays what older builds wrote (they read every server as SSH).
    public var sshEnabled = true

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
                credentialID: UUID? = nil, groupID: UUID? = nil, themeID: String? = nil,
                sessionDaemon: SessionBackend? = nil, lastSessionBackend: String? = nil,
                agentForwarding: ServerAgentSettings? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.credentialID = credentialID
        self.groupID = groupID
        self.themeID = themeID
        self.sessionDaemon = sessionDaemon
        self.lastSessionBackend = lastSessionBackend
        self.agentForwarding = agentForwarding
    }

    /// A copy that remembers `backend` as the last one used, or nil when it is already remembered (no vault write).
    public func rememberingSessionBackend(_ backend: String) -> Server? {
        guard lastSessionBackend != backend else { return nil }
        var copy = self
        copy.lastSessionBackend = backend
        return copy
    }
}

extension Server {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, credentialID, groupID, themeID, sessionDaemon, lastSessionBackend
        case resumeChoice, keptSessions, agentForwarding, jumpHosts, tags, notes, fontFamily, fontSize
        case sshEnabled = "ssh"
    }

    /// Vaults written before the session daemon have no `sessionDaemon`; one from a newer build may hold a backend
    /// this one does not know. Both mean "use the default" rather than a vault that fails to open.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  host: try c.decode(String.self, forKey: .host), port: try c.decode(Int.self, forKey: .port),
                  username: try c.decode(String.self, forKey: .username),
                  credentialID: try c.decodeIfPresent(UUID.self, forKey: .credentialID),
                  groupID: try c.decodeIfPresent(UUID.self, forKey: .groupID),
                  themeID: try c.decodeIfPresent(String.self, forKey: .themeID),
                  sessionDaemon: c.lenient(SessionBackend.self, .sessionDaemon),
                  lastSessionBackend: c.lenient(String.self, .lastSessionBackend))
        resumeChoice = c.lenient(ResumeChoice.self, .resumeChoice)
        keptSessions = c.lenient([KeptSession].self, .keptSessions) ?? []
        agentForwarding = c.lenient(ServerAgentSettings.self, .agentForwarding)
        // Older vaults have none; an entry this build cannot read drops the list rather than the vault.
        jumpHosts = c.lenient([JumpHost].self, .jumpHosts) ?? []
        tags = c.lenient([String].self, .tags) ?? []
        notes = c.lenient(String.self, .notes)
        fontFamily = c.lenient(String.self, .fontFamily)
        fontSize = c.lenient(Int.self, .fontSize)
        sshEnabled = c.lenient(Bool.self, .sshEnabled) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encodeIfPresent(credentialID, forKey: .credentialID)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encodeIfPresent(themeID, forKey: .themeID)
        try c.encodeIfPresent(sessionDaemon, forKey: .sessionDaemon)
        try c.encodeIfPresent(lastSessionBackend, forKey: .lastSessionBackend)
        try c.encodeIfPresent(resumeChoice, forKey: .resumeChoice)
        if !keptSessions.isEmpty { try c.encode(keptSessions, forKey: .keptSessions) }
        try c.encodeIfPresent(agentForwarding, forKey: .agentForwarding)
        if !jumpHosts.isEmpty { try c.encode(jumpHosts, forKey: .jumpHosts) }
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try c.encodeIfPresent(fontSize, forKey: .fontSize)
        if !sshEnabled { try c.encode(false, forKey: .sshEnabled) }
    }
}

/// A folder of servers in the server list (e.g. "Home", "OpenStack").
public struct ServerGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
