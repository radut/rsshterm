import Foundation
import RSSHKit

/// One `Host` alias of an OpenSSH client config, with the values ssh would use for it (first value wins, every
/// block whose patterns match the alias counts, in file order, `Host *` included).
public struct SSHConfigEntry: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFiles: [String] = []
    /// As written (`a,b` or `user@host:port`); kept for the jump-host chain.
    public var proxyJump: String?
    public var forwardAgent: Bool?
    /// 1-based line of the `Host` line that named the alias.
    public var line: Int

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil,
                identityFiles: [String] = [], proxyJump: String? = nil, forwardAgent: Bool? = nil, line: Int) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
        self.forwardAgent = forwardAgent
        self.line = line
    }

    /// Where ssh connects: HostName, else the alias itself.
    public var host: String { hostName ?? alias }
}

public struct SSHConfigParseResult: Equatable, Sendable {
    public var entries: [SSHConfigEntry]
    /// `Include` lines, not followed (the app may read and parse them too); rSshTerm's own include is left out.
    public var includes: [String]
    /// Lines that were read but not understood, with their numbers ("12: Match ..."), for the import sheet.
    public var notes: [String]
}

/// Reads an OpenSSH client config (~/.ssh/config). Only what a server entry needs is kept; `Match` blocks are skipped
/// (their conditions need the connection), wildcard and negated patterns name no server.
public enum SSHConfigParser {
    public static func parse(_ text: String) -> SSHConfigParseResult {
        var blocks: [Block] = []
        var current: Block? = Block(patterns: ["*"], line: 0, isMatch: false) // lines before the first Host
        var includes: [String] = []
        var notes: [String] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            guard let (keyword, value) = keywordAndValue(String(rawLine)) else { continue }
            switch keyword {
            case "host":
                if let current { blocks.append(current) }
                current = Block(patterns: words(value), line: number, isMatch: false)
            case "match":
                if let current { blocks.append(current) }
                current = Block(patterns: [], line: number, isMatch: true)
                notes.append("\(number): Match blocks are not imported")
            case "include":
                if !value.contains("rssh/ssh_config") { includes.append(unquoted(value)) }
            default:
                current?.settings.append((keyword, unquoted(value)))
            }
        }
        if let current { blocks.append(current) }

        var entries: [SSHConfigEntry] = []
        var seen: Set<String> = []
        for block in blocks where !block.isMatch {
            for alias in block.patterns where isPlainAlias(alias) && seen.insert(alias.lowercased()).inserted {
                entries.append(resolve(alias, line: block.line, blocks: blocks, notes: &notes))
            }
        }
        return SSHConfigParseResult(entries: entries, includes: includes, notes: notes)
    }

    // MARK: private

    private struct Block {
        var patterns: [String]
        var line: Int
        var isMatch: Bool
        var settings: [(String, String)] = []
    }

    private static func resolve(_ alias: String, line: Int, blocks: [Block], notes: inout [String]) -> SSHConfigEntry {
        var entry = SSHConfigEntry(alias: alias, line: line)
        for block in blocks where !block.isMatch && matches(alias, block.patterns) {
            for (keyword, value) in block.settings {
                switch keyword {
                case "hostname": if entry.hostName == nil { entry.hostName = expand(value, alias: alias) }
                case "user": if entry.user == nil { entry.user = value }
                case "port":
                    if entry.port == nil {
                        if let port = Int(value), (1...65535).contains(port) { entry.port = port }
                        else { notes.append("\(alias): port \(value) is not a number from 1 to 65535") }
                    }
                // IdentityFile accumulates in ssh too.
                case "identityfile": entry.identityFiles.append(value)
                case "proxyjump": if entry.proxyJump == nil, value.lowercased() != "none" { entry.proxyJump = value }
                case "forwardagent":
                    if entry.forwardAgent == nil { entry.forwardAgent = ["yes", "true"].contains(value.lowercased()) }
                default: break
                }
            }
        }
        return entry
    }

    /// "Keyword value", "Keyword=value", "Keyword = value"; comments and blank lines give nil. Keywords are
    /// case-insensitive; the value is as written (`Host` splits it into words, the others drop outer quotes).
    static func keywordAndValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (trimmed.lowercased(), "")
        }
        let keyword = trimmed[..<split].lowercased()
        var rest = trimmed[split...].drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        return (keyword, String(rest).trimmingCharacters(in: .whitespaces))
    }

    static func unquoted(_ value: String) -> String {
        value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
    }

    /// Space-separated words; "double quoted" words keep their spaces.
    static func words(_ value: String) -> [String] {
        var out: [String] = []
        var word = ""
        var quoted = false
        for ch in value {
            if ch == "\"" { quoted.toggle(); continue }
            if !quoted, ch == " " || ch == "\t" {
                if !word.isEmpty { out.append(word); word = "" }
            } else {
                word.append(ch)
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    private static func isPlainAlias(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains(where: { "*?!".contains($0) })
    }

    /// ssh's rule: a negated match excludes the block, otherwise any matching pattern includes it.
    static func matches(_ alias: String, _ patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), alias) { return false }
            } else if glob(pattern, alias) {
                matched = true
            }
        }
        return matched
    }

    /// `*` and `?`, case-insensitive (host names are).
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// `%h` in HostName is the alias (ssh's common use); `%%` is a percent sign.
    private static func expand(_ value: String, alias: String) -> String {
        value.replacingOccurrences(of: "%%", with: "\u{0}").replacingOccurrences(of: "%h", with: alias)
            .replacingOccurrences(of: "\u{0}", with: "%")
    }
}

/// One entry ready to import: the server it would make, and why it may be left out.
public struct SSHConfigImportCandidate: Equatable, Sendable, Identifiable {
    public var entry: SSHConfigEntry
    public var draft: ServerDraft
    /// A saved server with the same host, port and user (the import skips it unless asked).
    public var existing: UUID?
    /// Why the entry cannot become a server (no user, bad host); nil when it can.
    public var problem: String?

    public var id: String { entry.alias.lowercased() }
    public var isImportable: Bool { problem == nil }
}

public enum SSHConfigImport {
    /// One candidate per entry, against `vault` (duplicates) with `defaultUser` for entries without `User`
    /// (ssh would use the local login name).
    public static func candidates(_ result: SSHConfigParseResult, vault: Vault, defaultUser: String?,
                                  groupID: UUID? = nil) -> [SSHConfigImportCandidate] {
        result.entries.map { entry in
            let user = entry.user ?? defaultUser ?? ""
            let draft = ServerDraft(name: entry.alias, host: entry.host, port: String(entry.port ?? 22), username: user,
                                    groupID: groupID)
            let existing = vault.servers.first {
                $0.host.caseInsensitiveCompare(entry.host) == .orderedSame && $0.port == (entry.port ?? 22)
                    && $0.username == user
            }?.id
            let problem = draft.issues.first?.message
            return SSHConfigImportCandidate(entry: entry, draft: draft, existing: existing, problem: problem)
        }
    }

    /// An entry's `ProxyJump` as the vault's jump list: a hop naming an imported or saved server (by alias, name
    /// or host) is that server; `user@host:port` is an inline hop; a bare host takes the entry's user.
    public static func jumpHosts(_ entry: SSHConfigEntry, vault: Vault, imported: [String: UUID]) -> [JumpHost] {
        guard let proxy = entry.proxyJump else { return [] }
        return proxy.split(separator: ",").compactMap { raw -> JumpHost? in
            let token = raw.trimmingCharacters(in: .whitespaces)
            let lowered = token.lowercased()
            if let id = imported[lowered] { return .server(id) }
            if let saved = vault.servers.first(where: { $0.name.lowercased() == lowered || $0.host.lowercased() == lowered }) {
                return .server(saved.id)
            }
            guard let address = QuickAddress.parse(token.contains("@") ? token : "\(entry.user ?? "")@\(token)") else {
                return nil
            }
            return .inline(InlineJumpHost(host: address.host, port: address.port ?? 22, username: address.username))
        }
    }
}
