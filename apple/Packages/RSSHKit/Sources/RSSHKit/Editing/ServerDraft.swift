import Foundation

/// The server editor's fields as typed, before they are a valid `Server`. Port stays text so a half-typed value
/// can be shown and judged.
public struct ServerDraft: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable {
        case host, port, username

        public var message: String {
            switch self {
            case .host: "Enter a host name or IP address, without spaces."
            case .port: "The port is a number from 1 to 65535."
            case .username: "Enter a user name, without spaces."
            }
        }
    }

    public static let portRange = 1...65535

    public var name: String
    public var host: String
    public var port: String
    public var username: String
    public var groupID: UUID?
    public var credentialID: UUID?
    /// nil: the default theme from Settings.
    public var themeID: String?
    /// nil: the session daemon default from Settings.
    public var sessionDaemon: SessionBackend?
    /// Carried through unchanged: the editor shows it, the connection sets it.
    public var lastSessionBackend: String?
    /// nil: ask.
    public var resumeChoice: ResumeChoice?
    /// Carried through unchanged.
    public var keptSessions: [KeptSession] = []
    /// nil: follow Settings › SSH with this server's own key.
    public var agentForwarding: ServerAgentSettings?
    /// The "Jump Through" list, in order.
    public var jumpHosts: [JumpHost] = []
    /// As typed; trimmed, emptied and de-duplicated (case ignored) on save.
    public var tags: [String] = []
    /// Blank notes are saved as none.
    public var notes: String?
    /// nil: the font from Settings.
    public var fontFamily: String?
    /// nil: the size from Settings; clamped to `TerminalPreferences.fontSizeRange` on save.
    public var fontSize: Int?
    /// False: the server is opened only as a screen (its RDP or VNC service).
    public var sshEnabled = true

    public init(name: String = "", host: String = "", port: String = "22", username: String = "",
                groupID: UUID? = nil, credentialID: UUID? = nil, themeID: String? = nil,
                sessionDaemon: SessionBackend? = nil, lastSessionBackend: String? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.groupID = groupID
        self.credentialID = credentialID
        self.themeID = themeID
        self.sessionDaemon = sessionDaemon
        self.lastSessionBackend = lastSessionBackend
    }

    public init(server: Server) {
        self.init(name: server.name, host: server.host, port: String(server.port), username: server.username,
                  groupID: server.groupID, credentialID: server.credentialID, themeID: server.themeID,
                  sessionDaemon: server.sessionDaemon, lastSessionBackend: server.lastSessionBackend)
        resumeChoice = server.resumeChoice
        keptSessions = server.keptSessions
        agentForwarding = server.agentForwarding
        jumpHosts = server.jumpHosts
        tags = server.tags
        notes = server.notes
        fontFamily = server.fontFamily
        fontSize = server.fontSize
        sshEnabled = server.sshEnabled
    }

    /// The fields that are wrong, in form order; empty when the draft is valid.
    public var issues: [Field] {
        var found: [Field] = []
        if !Self.isValidHost(trimmed(host)) { found.append(.host) }
        if parsedPort == nil { found.append(.port) }
        if !Self.isValidUsername(trimmed(username)) { found.append(.username) }
        return found
    }

    public func makeServer(id: UUID) throws(ServerDraftError) -> Server {
        let problems = issues
        guard problems.isEmpty, let port = parsedPort else { throw ServerDraftError(issues: problems) }
        let host = trimmed(host)
        let name = trimmed(name)
        var server = Server(id: id, name: name.isEmpty ? host : name, host: host, port: port,
                            username: trimmed(username), credentialID: credentialID, groupID: groupID, themeID: themeID,
                            sessionDaemon: sessionDaemon, lastSessionBackend: lastSessionBackend)
        server.resumeChoice = resumeChoice
        server.keptSessions = keptSessions
        server.agentForwarding = agentForwarding
        server.jumpHosts = jumpHosts
        server.sshEnabled = sshEnabled
        server.tags = Self.cleanTags(tags)
        let note = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        server.notes = note.isEmpty ? nil : notes
        let family = fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        server.fontFamily = family.isEmpty ? nil : family
        server.fontSize = fontSize.map {
            min(max($0, TerminalPreferences.fontSizeRange.lowerBound), TerminalPreferences.fontSizeRange.upperBound)
        }
        return server
    }

    /// Trimmed, no empty ones, the first spelling of each (case ignored), in the order typed.
    public static func cleanTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            out.append(tag)
        }
        return out
    }

    private var parsedPort: Int? {
        guard let value = Int(trimmed(port)), Self.portRange.contains(value) else { return nil }
        return value
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Host names, IPv4, IPv6 (bare or in brackets, with an optional %zone).
    static func isValidHost(_ host: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:[]%"))
        return !host.isEmpty && host.count <= 253 && host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isValidUsername(_ name: String) -> Bool {
        !name.isEmpty && !name.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 }
    }
}

public struct ServerDraftError: Error, Equatable, Sendable, LocalizedError {
    public let issues: [ServerDraft.Field]

    public init(issues: [ServerDraft.Field]) { self.issues = issues }

    public var errorDescription: String? { issues.map(\.message).joined(separator: " ") }
}
