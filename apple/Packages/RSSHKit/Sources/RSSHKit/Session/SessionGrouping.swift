import Foundation

/// What the sessions drawer needs to know about one open session.
public struct OpenSessionInfo: Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The vault server, or a Quick Connect entry (not in the vault).
    public var serverID: UUID
    public var title: String
    public var openedAt: Date

    public init(id: UUID, serverID: UUID, title: String, openedAt: Date) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.openedAt = openedAt
    }
}

/// One row of the drawer: the session and its title, numbered ("web-1 #2") when its server has several open.
public struct SessionEntry: Hashable, Identifiable, Sendable {
    public var session: OpenSessionInfo
    public var number: Int?
    public var id: UUID { session.id }
    public var title: String { number.map { "\(session.title) #\($0)" } ?? session.title }
}

/// Sessions under one folder of the server list, or under "Other".
public struct SessionSection: Hashable, Identifiable, Sendable {
    /// nil for "Other": servers without a folder, Quick Connect and servers no longer in the vault.
    public var groupID: UUID?
    /// nil when "Other" is the only section (no header needed).
    public var title: String?
    public var entries: [SessionEntry]
    public var id: String { groupID?.uuidString ?? "other" }
}

/// Groups open sessions the way the server list groups servers: folders in their order, then "Other".
public enum SessionGrouping {
    public static func sections(_ sessions: [OpenSessionInfo], servers: [Server], groups: [ServerGroup])
        -> [SessionSection] {
        let numbers = numbers(sessions)
        let folderOf = Dictionary(servers.map { ($0.id, $0.groupID) }, uniquingKeysWith: { first, _ in first })
        let known = Set(groups.map(\.id))
        let ordered = sessions.enumerated().sorted { lhs, rhs in
            (lhs.element.openedAt, lhs.offset) < (rhs.element.openedAt, rhs.offset)
        }.map(\.element)
        var byFolder: [UUID?: [SessionEntry]] = [:]
        for session in ordered {
            let folder = folderOf[session.serverID].flatMap { $0 }.flatMap { known.contains($0) ? $0 : nil }
            byFolder[folder, default: []].append(SessionEntry(session: session, number: numbers[session.id]))
        }
        var result = groups.compactMap { group in
            byFolder[group.id].map { SessionSection(groupID: group.id, title: group.name, entries: $0) }
        }
        if let other = byFolder[nil] {
            result.append(SessionSection(groupID: nil, title: result.isEmpty ? nil : "Other", entries: other))
        }
        return result
    }

    /// 1, 2, … per server in opening order, only for servers with more than one session open.
    public static func numbers(_ sessions: [OpenSessionInfo]) -> [UUID: Int] {
        let byServer = Dictionary(grouping: sessions, by: \.serverID)
        var result: [UUID: Int] = [:]
        for (_, same) in byServer where same.count > 1 {
            for (index, session) in same.sorted(by: { $0.openedAt < $1.openedAt }).enumerated() {
                result[session.id] = index + 1
            }
        }
        return result
    }

    /// The session ids top to bottom, as the drawer shows them (for Cmd+1…9).
    public static func flatOrder(_ sections: [SessionSection]) -> [UUID] {
        sections.flatMap { $0.entries.map(\.id) }
    }
}

/// What tapping a server does when it may already have sessions open.
public enum SessionOpenDecision: Equatable, Sendable {
    /// Open a new session (none is open, or the user asked for a new one).
    case connect
    /// Ask: switch to one of these sessions, or open another.
    case ask([UUID])

    public static func decide(openSessions: [UUID], explicitNew: Bool) -> SessionOpenDecision {
        explicitNew || openSessions.isEmpty ? .connect : .ask(openSessions)
    }
}
