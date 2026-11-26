import Foundation
import RSSHKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A vault key as ssh_config needs it: the one-line public key written to `keys/<credential id>.pub`.
public struct SSHConfigKey: Equatable, Sendable {
    public let credentialID: UUID
    public let publicLine: String

    public init(credentialID: UUID, publicLine: String) {
        self.credentialID = credentialID
        self.publicLine = publicLine
    }

    public init(_ key: AgentKey) {
        self.init(credentialID: key.id,
                  publicLine: SSHPublicKey.line(type: key.keyType, blob: key.identity.publicBlob, comment: key.label))
    }
}

/// What gets written under ~/.config/rssh: the config text and the public key files (name → content).
public struct SSHConfigFiles: Equatable, Sendable {
    public let config: String
    public let publicKeys: [String: String]
    /// Servers left out because a field cannot be written safely into ssh_config, with the reason.
    public let skipped: [String: String]
}

/// Turns the vault's servers into an ssh_config include, so `ssh <name>` (or `ssh <host>` when only one server has
/// that host) in a local tab connects with the vault's user, port and key: IdentityAgent points at the built-in
/// agent and IdentityFile at the server key's public half with IdentitiesOnly, so ssh offers that key first and
/// only that key, never every key in the vault (servers cut off after a few failed keys).
public enum SSHConfigGenerator {
    public static let header = """
    # rSshTerm: generated from the vault on every change; edits here are overwritten.
    # Use it from ~/.ssh/config, ABOVE any Host or Match block:
    #   Include ~/.config/rssh/ssh_config

    """

    public static func generate(servers: [Server], keys: [SSHConfigKey], agentSocket: String,
                                keyDirectory: String) -> SSHConfigFiles {
        let keysByID = Dictionary(keys.map { ($0.credentialID, $0) }) { first, _ in first }
        var hostCounts: [String: Int] = [:]
        for server in servers { hostCounts[server.host.lowercased(), default: 0] += 1 }
        let skipped = skippedServers(servers)
        let written = ordered(servers).filter { skipped[$0.id] == nil }

        // Server aliases first (`aliases(for:)`): a server's ProxyJump names its jump servers by theirs; inline hop
        // blocks take names after them.
        let aliases = Self.aliases(for: servers)
        var usedAliases = Set(aliases.values)
        func claim(_ wanted: String) -> String {
            var candidate = wanted
            var n = 2
            while usedAliases.contains(candidate) {
                candidate = "\(wanted)-\(n)"
                n += 1
            }
            usedAliases.insert(candidate)
            return candidate
        }
        // Inline hop names are claimed before any block is written, so no server's host pattern can take one.
        var hopNames: [UUID: [Int: String]] = [:]
        for server in written {
            guard let alias = aliases[server.id] else { continue }
            for (index, jump) in server.jumpHosts.enumerated() {
                if case .inline = jump { hopNames[server.id, default: [:]][index] = claim("\(alias)-jump-\(index + 1)") }
            }
        }

        var blocks: [String] = []
        var files: [String: String] = [:]
        func entry(_ patterns: [String], _ target: ConnectionTarget, credentialID: UUID?, proxyJump: [String]) -> String {
            var lines = ["Host \(patterns.joined(separator: " "))",
                         "    HostName \(target.host)",
                         "    User \(target.username)",
                         "    Port \(target.port)",
                         "    IdentityAgent \(quoted(agentSocket))"]
            if let id = credentialID, let key = keysByID[id] {
                let file = "\(id.uuidString.lowercased()).pub"
                files[file] = key.publicLine + "\n"
                lines.append("    IdentityFile \(quoted("\(keyDirectory)/\(file)"))")
                lines.append("    IdentitiesOnly yes")
            }
            if !proxyJump.isEmpty { lines.append("    ProxyJump \(proxyJump.joined(separator: ","))") }
            return lines.joined(separator: "\n")
        }
        for server in written {
            guard let alias = aliases[server.id] else { continue }
            var patterns = [alias]
            let host = server.host.lowercased()
            if hostCounts[host] == 1, host != alias, !usedAliases.contains(host) { patterns.append(server.host) }
            // An inline hop gets a block of its own, so its ssh also logs in through the agent with its key.
            var jumps: [String] = []
            var hopBlocks: [String] = []
            for (index, jump) in server.jumpHosts.enumerated() {
                switch jump {
                case .server(let id):
                    if let name = aliases[id] { jumps.append(name) }
                case .inline(let hop):
                    guard let name = hopNames[server.id]?[index] else { continue }
                    jumps.append(name)
                    hopBlocks.append(entry([name], hop.target, credentialID: hop.credentialID ?? server.credentialID,
                                           proxyJump: []))
                }
            }
            blocks.append(entry(patterns, ConnectionTarget(server: server), credentialID: server.credentialID,
                                proxyJump: jumps))
            blocks += hopBlocks
        }
        var reasons: [String: String] = [:]
        for server in servers { if let reason = skipped[server.id] { reasons[server.name] = reason } }
        return SSHConfigFiles(config: header + blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n"),
                              publicKeys: files, skipped: reasons)
    }

    /// The `Host` alias of each server the config holds (`ssh <alias>` opens it), by server id: the name as
    /// `alias(for:)` writes it, `-2`, `-3` … on a clash, in the order the blocks are written. Servers the file
    /// leaves out (a host or user that would break it, a jump chain that cannot be followed) have none. Inline jump
    /// hops get their own `<alias>-jump-<n>` blocks, which are not servers and are not listed.
    public static func aliases(for servers: [Server]) -> [UUID: String] {
        let skipped = skippedServers(servers)
        var used: Set<String> = []
        var result: [UUID: String] = [:]
        for server in ordered(servers) where skipped[server.id] == nil {
            var alias = Self.alias(for: server.name)
            if alias.isEmpty { alias = "server" }
            var candidate = alias
            var n = 2
            while used.contains(candidate) {
                candidate = "\(alias)-\(n)"
                n += 1
            }
            used.insert(candidate)
            result[server.id] = candidate
        }
        return result
    }

    private static func ordered(_ servers: [Server]) -> [Server] {
        servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Servers that cannot be written, by id, with the reason: an unsafe field, or ("jump host") a jump chain that
    /// cannot be followed (a circle, too long, a deleted or skipped jump server, an unsafe inline hop).
    private static func skippedServers(_ servers: [Server]) -> [UUID: String] {
        var skipped: [UUID: String] = [:]
        for server in servers {
            if let reason = problem(with: ConnectionTarget(server: server)) { skipped[server.id] = reason }
        }
        for server in servers where skipped[server.id] == nil && !server.jumpHosts.isEmpty {
            let hops = try? JumpChain.hops(to: server, in: servers)
            let followable = hops?.allSatisfy { hop in
                problem(with: hop.target) == nil && hop.serverID.map { skipped[$0] == nil } ?? true
            } ?? false
            if !followable { skipped[server.id] = "jump host" }
        }
        return skipped
    }

    /// `Backup NAS` → `backup-nas`: lowercase letters, digits, dot, dash and underscore.
    public static func alias(for name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" {
                out.append(ch)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// ssh_config splits on whitespace, treats `#` as a comment, `*?!,` as patterns and `%` as a token: values with
    /// any of these (or quotes, or control characters) would change what the file means.
    private static func problem(with target: ConnectionTarget) -> String? {
        let unsafe = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"'#*?!,%\\"))
        if target.host.isEmpty || target.host.hasPrefix("-") || target.host.unicodeScalars.contains(where: unsafe.contains) {
            return "host"
        }
        if target.username.isEmpty || target.username.hasPrefix("-")
            || target.username.unicodeScalars.contains(where: unsafe.contains) { return "user" }
        if !(1...65535).contains(target.port) { return "port" }
        return nil
    }

    /// A double-quoted path; `%` doubled because ssh expands %-tokens in IdentityAgent and IdentityFile.
    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "%", with: "%%") + "\""
    }
}

/// Writes the generated files: `<directory>/ssh_config` (0600) and `<directory>/keys/*.pub` (0644; stale ones
/// removed), the directory 0700. Default directory: $XDG_CONFIG_HOME/rssh, else ~/.config/rssh.
public struct SSHConfigWriter: Sendable {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    public static func defaultDirectory(environment: [String: String], home: String = NSHomeDirectory()) -> String {
        if let config = environment["XDG_CONFIG_HOME"], config.hasPrefix("/") { return "\(config)/rssh" }
        return "\(home)/.config/rssh"
    }

    public var configPath: String { "\(directory)/ssh_config" }
    public var keyDirectory: String { "\(directory)/keys" }

    public func write(_ files: SSHConfigFiles) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        try fm.createDirectory(atPath: keyDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in try fm.contentsOfDirectory(atPath: keyDirectory) where name.hasSuffix(".pub") && files.publicKeys[name] == nil {
            try fm.removeItem(atPath: "\(keyDirectory)/\(name)")
        }
        for (name, content) in files.publicKeys {
            try atomicWrite(content, to: "\(keyDirectory)/\(name)", mode: 0o644)
        }
        try atomicWrite(files.config, to: configPath, mode: 0o600)
    }

    /// Write to a temporary file with the final mode, then rename over the target.
    private func atomicWrite(_ text: String, to path: String, mode: Int) throws {
        let temporary = "\(path).tmp-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: temporary, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary])
        }
        guard rename(temporary, path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(atPath: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
