import Foundation

/// How long a kept session lives on the server. `idle`: closes after this long with no input or output (a running
/// program keeps it open). `hard`: closes this long after it was made, whatever happens. 0 turns a limit off.
public struct SessionTimeouts: Codable, Hashable, Sendable {
    public var idleSeconds: Int
    public var hardSeconds: Int

    public init(idleSeconds: Int, hardSeconds: Int) {
        self.idleSeconds = Self.clamp(idleSeconds)
        self.hardSeconds = Self.clamp(hardSeconds)
    }

    /// The app's default: a quiet session holds a day, none lives past a week.
    public static let standard = SessionTimeouts(idleSeconds: 24 * hour, hardSeconds: 7 * day)

    /// What the pickers offer, shortest first; 0 (Never) last.
    public static let choices: [Int] = [hour, 4 * hour, 8 * hour, day, 3 * day, 7 * day, 30 * day, 0]

    /// The daemon refuses more than a year (rsshd `maxTimeoutSecs`).
    public static let maxSeconds = 365 * day

    /// "24 hours", "3 days", "Never".
    public static func title(_ seconds: Int) -> String {
        if seconds <= 0 { return "Never" }
        if seconds % day == 0 { let n = seconds / day; return n == 1 ? "1 day" : "\(n) days" }
        if seconds % hour == 0 { let n = seconds / hour; return n == 1 ? "1 hour" : "\(n) hours" }
        let minutes = max(1, seconds / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// `choices`, plus `current` when it is not one of them (a value set on the server), in order.
    public static func choices(including current: Int) -> [Int] {
        guard !choices.contains(current) else { return choices }
        return (choices.filter { $0 > 0 } + [current]).sorted() + [0]
    }

    private static let hour = 3600
    private static let day = 24 * 3600

    private static func clamp(_ seconds: Int) -> Int { min(max(seconds, 0), maxSeconds) }

    private enum CodingKeys: String, CodingKey { case idleSeconds, hardSeconds }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.standard
        self.init(idleSeconds: (try? c.decodeIfPresent(Int.self, forKey: .idleSeconds)) ?? d.idleSeconds,
                  hardSeconds: (try? c.decodeIfPresent(Int.self, forKey: .hardSeconds)) ?? d.hardSeconds)
    }
}

/// `timeouts` of `create` and the body of `set_timeouts` (PROTOCOL.md).
struct RsshdTimeoutArgs: Encodable, Sendable {
    var id: String?
    var idleS: Int
    var hardS: Int

    init(id: String? = nil, _ timeouts: SessionTimeouts) {
        self.id = id
        idleS = timeouts.idleSeconds
        hardS = timeouts.hardSeconds
    }

    private enum CodingKeys: String, CodingKey { case id, idleS = "idle_s", hardS = "hard_s" }
}

extension RsshdSession.Timeouts {
    /// The idle and hard limits as the app's type.
    public var sessionTimeouts: SessionTimeouts { SessionTimeouts(idleSeconds: idleS, hardSeconds: hardS) }
}
