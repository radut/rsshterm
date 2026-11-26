import Foundation

/// The identification line an SSH server sends first ("SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13", RFC 4253 4.2).
public struct SSHBanner: Hashable, Sendable {
    /// "2.0" (or "1.99").
    public var protocolVersion: String
    /// "OpenSSH_9.6p1".
    public var software: String
    /// What follows the software, "Ubuntu-3ubuntu13"; empty when absent.
    public var comment: String

    /// nil unless the line starts with "SSH-" and names a protocol and software. Trailing CR/LF is ignored.
    public init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("SSH-") else { return nil }
        let rest = trimmed.dropFirst(4)
        let (ident, comment) = rest.firstIndex(of: " ").map { (rest[..<$0], rest[rest.index(after: $0)...]) }
            ?? (rest, "")
        guard let dash = ident.firstIndex(of: "-") else { return nil }
        let version = ident[..<dash], software = ident[ident.index(after: dash)...]
        guard !version.isEmpty, !software.isEmpty else { return nil }
        protocolVersion = String(version)
        self.software = String(software)
        self.comment = String(comment).trimmingCharacters(in: .whitespaces)
    }

    /// "OpenSSH 9.6p1": the software with its first "_" read as a space.
    public var softwareName: String {
        guard let underscore = software.firstIndex(of: "_") else { return software }
        return software[..<underscore] + " " + software[software.index(after: underscore)...]
    }

    /// The system the banner gives away, if any ("Ubuntu", "Debian", "Windows").
    public var osHint: String? {
        let text = (software + " " + comment).lowercased()
        return Self.hints.first { text.contains($0.needle) }?.name
    }

    /// One line for the scan list: "OpenSSH 9.6p1 · Ubuntu".
    public var summary: String {
        [softwareName, osHint].compactMap { $0 }.joined(separator: " · ")
    }

    private static let hints: [(needle: String, name: String)] = [
        ("ubuntu", "Ubuntu"), ("raspbian", "Raspberry Pi OS"), ("debian", "Debian"), ("freebsd", "FreeBSD"),
        ("netbsd", "NetBSD"), ("openbsd", "OpenBSD"), ("for_windows", "Windows"), ("windows", "Windows"),
        ("dropbear", "embedded (Dropbear)"), ("rosssh", "MikroTik"), ("cisco", "Cisco"), ("synology", "Synology"),
        ("fedora", "Fedora"),
    ]
}
