import Foundation

/// The rsshd release this app build offers. Bumped with each `rsshd-v*` tag the app is meant to run against; a server
/// with an older rsshd is offered the upgrade.
public enum RsshdRelease {
    public static let latest = "1.0.0"

    /// True when `version` ("0.1.0", "v0.1.0", "0.1.0-rc1") is older than `than`. Unknown versions ("dev", "") are
    /// never called old: a hand-built daemon is not nagged.
    public static func isOlder(_ version: String, than other: String = latest) -> Bool {
        guard let a = parts(version), let b = parts(other) else { return false }
        return a.lexicographicallyPrecedes(b)
    }

    /// Major, minor, patch as numbers; nil when it does not start with digits.
    static func parts(_ version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        let core = text.prefix { $0.isNumber || $0 == "." }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        let values = numbers.compactMap { $0 }
        return Array((values + [0, 0, 0]).prefix(3))
    }
}
