import Foundation

/// An absolute, normalised POSIX-style path inside one file source ("/" is the source's root). "." and empty
/// segments are dropped and ".." pops a segment but never climbs above the root, so a path can never escape it.
public struct FilePath: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let root = FilePath(segments: [])

    /// The names from the root down, none empty, none "." or "..".
    public let segments: [String]

    public init(_ string: String) {
        var out: [String] = []
        for part in string.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !out.isEmpty { out.removeLast() }
            default: out.append(String(part))
            }
        }
        segments = out
    }

    public init(segments: [String]) {
        self.init("/" + segments.joined(separator: "/"))
    }

    public var string: String { "/" + segments.joined(separator: "/") }
    public var description: String { string }
    public var isRoot: Bool { segments.isEmpty }

    /// The last segment; "/" for the root.
    public var name: String { segments.last ?? "/" }

    /// The folder holding this path; the root is its own parent.
    public var parent: FilePath { isRoot ? self : FilePath(segments: Array(segments.dropLast())) }

    /// The extension after the last dot of the name ("" for none, and for dot files such as ".profile").
    public var pathExtension: String {
        let name = self.name
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// `name` relative to this folder. A name with "/" adds several segments; ".." cannot climb above the root.
    public func appending(_ name: String) -> FilePath {
        FilePath(string + "/" + name)
    }

    /// True when `other` is this path or lies below it.
    public func contains(_ other: FilePath) -> Bool {
        other.segments.count >= segments.count && Array(other.segments.prefix(segments.count)) == segments
    }

    /// This path moved from below `base` to below `newBase` (`base` must contain it).
    public func rebased(from base: FilePath, onto newBase: FilePath) -> FilePath {
        FilePath(segments: newBase.segments + segments.dropFirst(base.segments.count))
    }

    /// Breadcrumbs: the root, then each ancestor down to this path.
    public var ancestry: [FilePath] {
        (0...segments.count).map { FilePath(segments: Array(segments.prefix($0))) }
    }

    public static func < (lhs: FilePath, rhs: FilePath) -> Bool { lhs.string < rhs.string }
}

/// Picks a free name for a copy that would collide: "a.txt" -> "a (1).txt", "a (1).txt" -> "a (2).txt".
public enum FileNaming {
    public static func variant(of name: String, number: Int) -> String {
        let path = FilePath("/" + name)
        let ext = path.pathExtension
        var stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        if let match = stem.range(of: #" \(\d+\)$"#, options: .regularExpression) { stem.removeSubrange(match) }
        return ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
    }

    /// The first variant of `name` for which `isTaken` is false (tries up to 999, then a UUID suffix).
    public static func freeName(for name: String, isTaken: (String) async throws -> Bool) async rethrows -> String {
        for number in 1..<1000 {
            let candidate = variant(of: name, number: number)
            if try await !isTaken(candidate) { return candidate }
        }
        return variant(of: name, number: 0) + "-" + UUID().uuidString.prefix(8)
    }
}
