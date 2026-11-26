import Foundation

/// The username list Quick Connect offers after the hosts are entered.
extension TerminalPreferences {
    public static let defaultQuickConnectUsers = ["root", "ubuntu"]

    /// The list as Quick Connect shows it: the last used user first (also when it was typed via "Other…").
    public var orderedQuickConnectUsers: [String] {
        guard let last = lastQuickConnectUser.map(Self.trimmed), !last.isEmpty else { return quickConnectUsers }
        return [last] + quickConnectUsers.filter { $0 != last }
    }

    /// A copy that remembers `user` as the last one used.
    public func usingQuickConnectUser(_ user: String) -> TerminalPreferences {
        var copy = self
        let name = Self.trimmed(user)
        copy.lastQuickConnectUser = name.isEmpty ? nil : name
        return copy
    }

    /// A copy with `user` appended (ignored when blank or already listed).
    public func addingQuickConnectUser(_ user: String) -> TerminalPreferences {
        var copy = self
        copy.quickConnectUsers = quickConnectUsers + [user]
        return copy
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func cleaned(_ users: [String]) -> [String] {
        var seen = Set<String>()
        return users.map(trimmed).filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) && seen.insert($0).inserted }
    }
}
