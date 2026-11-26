import Foundation

/// What connecting to a server with kept sessions does when some are not open on this device.
public enum ResumeChoice: String, Codable, CaseIterable, Sendable {
    /// Show the server's sessions and let the user pick (the default).
    case ask
    /// Attach the one with the newest activity, without asking.
    case last
    /// Always start a new session.
    case new

    public var title: String {
        switch self {
        case .ask: "Always ask"
        case .last: "Resume the last one"
        case .new: "Always new"
        }
    }
}

/// One rsshd session this user keeps on a server: the vault remembers it (synced), so a phone that lost its tabs,
/// or another device, knows there is something to resume. `name` is the tab's name here; the server keeps the
/// name it was created with (the protocol has no rename).
public struct KeptSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var lastSeen: Date

    public init(id: String, name: String, lastSeen: Date) {
        self.id = id
        self.name = name
        self.lastSeen = lastSeen
    }
}

extension Server {
    /// Seen again within this long, the vault is not written just to move `lastSeen`.
    static let keptRefreshInterval: TimeInterval = 3600

    public var effectiveResumeChoice: ResumeChoice { resumeChoice ?? .ask }

    /// Records that a tab attached `id`; nil when nothing worth saving changed.
    public func recordingKept(id: String, name: String, at now: Date) -> Server? {
        var copy = self
        if let index = keptSessions.firstIndex(where: { $0.id == id }) {
            let old = keptSessions[index]
            guard old.name != name || now.timeIntervalSince(old.lastSeen) >= Self.keptRefreshInterval else { return nil }
            copy.keptSessions[index] = KeptSession(id: id, name: name, lastSeen: now)
        } else {
            copy.keptSessions.append(KeptSession(id: id, name: name, lastSeen: now))
        }
        return copy
    }

    public func renamingKept(id: String, to name: String) -> Server? {
        guard let index = keptSessions.firstIndex(where: { $0.id == id }), keptSessions[index].name != name else {
            return nil
        }
        var copy = self
        copy.keptSessions[index].name = name
        return copy
    }

    /// Keeps only the ids the server still has (a `list` answer); nil when none went away.
    public func keepingKept(onlyIDs ids: Set<String>) -> Server? {
        let kept = keptSessions.filter { ids.contains($0.id) }
        guard kept.count != keptSessions.count else { return nil }
        var copy = self
        copy.keptSessions = kept
        return copy
    }

    public func forgettingKept(id: String) -> Server? {
        keepingKept(onlyIDs: Set(keptSessions.map(\.id)).subtracting([id]))
    }
}
