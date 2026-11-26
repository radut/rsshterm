import Foundation

/// Text helpers for tab titles: ellipses, `~` for the home folder, short paths and the final clean-up.
public enum TitleText {
    public static let ellipsis: Character = "…"

    /// `text` cut to `max` characters by taking out its middle (paths and arguments keep both ends).
    public static func middleEllipsis(_ text: String, max: Int) -> String {
        guard max > 0 else { return "" }
        guard text.count > max else { return text }
        guard max > 1 else { return String(ellipsis) }
        let keep = max - 1
        let head = (keep + 1) / 2
        let tail = keep - head
        return String(text.prefix(head)) + String(ellipsis) + String(text.suffix(tail))
    }

    /// `text` cut to `max` characters at its end.
    public static func endEllipsis(_ text: String, max: Int) -> String {
        guard max > 0 else { return "" }
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)) + String(ellipsis)
    }

    /// `path` with the home folder written as `~`.
    public static func abbreviateHome(_ path: String, home: String?) -> String {
        guard let home = home.map(trimSlash), !home.isEmpty, home != "/" else { return path }
        let trimmed = trimSlash(path)
        if trimmed == home { return "~" }
        if trimmed.hasPrefix(home + "/") { return "~" + trimmed.dropFirst(home.count) }
        return path
    }

    /// The folder as a tab shows it: `~` for home, then at most its last two parts (`…/nginx/sites-enabled`).
    public static func shortPath(_ path: String, home: String?) -> String {
        let abbreviated = abbreviateHome(trimSlash(path), home: home)
        let rooted = abbreviated.hasPrefix("/")
        let parts = abbreviated.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.isEmpty { return rooted ? "/" : abbreviated }
        let keep = parts.first == "~" ? 3 : 2
        if parts.count <= keep { return (rooted ? "/" : "") + parts.joined(separator: "/") }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    /// The likely home folder of a remote `user`, when `path` lies in it (`/root`, `/home/u`, `/Users/u`).
    public static func guessHome(user: String?, path: String?) -> String? {
        guard let user, !user.isEmpty, let path else { return nil }
        let candidates = user == "root" ? ["/root", "/var/root"] : ["/home/" + user, "/Users/" + user]
        return candidates.first { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Control characters out, whitespace runs to one space, and no separator left hanging at either end.
    public static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            let isSpace = scalar.properties.isWhitespace
            if isSpace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else if scalar.properties.generalCategory == .control {
                continue
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var words = String(scalars).split(separator: " ").map(String.init)
        let separators: Set<Character> = ["·", "-", "—", "–", "|", ":", "•", "›"]
        let isSeparator = { (word: String) in word.allSatisfy { separators.contains($0) } }
        while let first = words.first, isSeparator(first) { words.removeFirst() }
        while let last = words.last, isSeparator(last) { words.removeLast() }
        let attached: Set<Character> = ["@", ":", "·"]
        if var first = words.first {
            while let c = first.first, attached.contains(c) { first.removeFirst() }
            words[0] = first
        }
        if var last = words.last {
            while let c = last.last, attached.contains(c) { last.removeLast() }
            words[words.count - 1] = last
        }
        return words.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func trimSlash(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
