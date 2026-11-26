import Foundation

/// A vault server as a tab title sees it.
public struct VaultHostFacts: Equatable, Sendable, Codable {
    public var name: String?
    public var host: String
    public var user: String?
    public var port: Int?

    public init(name: String?, host: String, user: String?, port: Int? = nil) {
        self.name = name
        self.host = host
        self.user = user
        self.port = port
    }
}

/// The target of an `ssh`/`mosh`/`autossh` command line: what a local tab connects to.
public struct SSHCommandLine: Equatable, Sendable {
    public var user: String?
    /// The destination as typed (an alias, a host name or an address; IPv6 without brackets).
    public var destination: String
    public var port: Int?
    /// Words after the destination (`ssh h htop` -> ["htop"]).
    public var remoteCommand: [String]

    public init(user: String? = nil, destination: String, port: Int? = nil, remoteCommand: [String] = []) {
        self.user = user
        self.destination = destination
        self.port = port
        self.remoteCommand = remoteCommand
    }

    /// Programs whose command line names an SSH destination.
    public static let programs: Set<String> = ["ssh", "mosh", "autossh", "et"]
    /// ssh's options that take a value (OpenSSH 9: `ssh -?` usage).
    static let valueOptions: Set<Character> = ["B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O",
                                               "o", "P", "p", "Q", "R", "S", "W", "w"]
    /// autossh's own options with a value.
    static let autosshValueOptions: Set<String> = ["-M"]

    /// Nil when `argv` is not one of `programs` or names no destination.
    public static func parse(_ argv: [String]) -> SSHCommandLine? {
        guard let first = argv.first else { return nil }
        let program = CommandFacts.programName(first)
        guard programs.contains(program) else { return nil }
        var user: String?
        var port: Int?
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" { i += 1; break }
            guard arg.hasPrefix("-"), arg.count > 1 else { break }
            if program == "autossh", autosshValueOptions.contains(arg) { i += 2; continue }
            if program == "mosh" || program == "et", arg.hasPrefix("--") { i += 1; continue }
            let letters = Array(arg.dropFirst())
            var j = 0
            var consumedNext = false
            while j < letters.count {
                let letter = letters[j]
                guard valueOptions.contains(letter) else { j += 1; continue }
                let attached = String(letters[(j + 1)...])
                let value: String
                if attached.isEmpty {
                    guard i + 1 < argv.count else { return nil }
                    value = argv[i + 1]
                    consumedNext = true
                } else {
                    value = attached
                }
                switch letter {
                case "l": user = value
                case "p": port = Int(value)
                case "o": apply(option: value, user: &user, port: &port)
                default: break
                }
                break
            }
            i += consumedNext ? 2 : 1
        }
        guard i < argv.count else { return nil }
        guard var target = parseDestination(argv[i]) else { return nil }
        if target.user == nil { target.user = user }
        if target.port == nil { target.port = port }
        target.remoteCommand = Array(argv[(i + 1)...])
        return target
    }

    private static func apply(option: String, user: inout String?, port: inout Int?) {
        let pair = option.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == " " }).map(String.init)
        guard pair.count == 2 else { return }
        switch pair[0].lowercased() {
        case "user": user = pair[1]
        case "port": port = Int(pair[1])
        default: break
        }
    }

    /// `user@host`, `host`, `ssh://user@host:port`, `user@[v6]`.
    static func parseDestination(_ text: String) -> SSHCommandLine? {
        var rest = Substring(text)
        var port: Int?
        let isURL = rest.lowercased().hasPrefix("ssh://")
        if isURL { rest = rest.dropFirst("ssh://".count) }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var host: String
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if isURL, after.hasPrefix(":") { port = Int(after.dropFirst()) }
        } else {
            host = String(rest)
            if isURL, let colon = rest.lastIndex(of: ":") {
                host = String(rest[..<colon])
                port = Int(rest[rest.index(after: colon)...])
            }
        }
        if isURL, host.hasSuffix("/") { host.removeLast() }
        guard !host.isEmpty, user?.isEmpty != true else { return nil }
        return SSHCommandLine(user: user, destination: host, port: port)
    }

    /// The connection after ssh_config and the vault: `alias` is what was typed when it differs from the host.
    public struct Resolved: Equatable, Sendable {
        public var user: String?
        public var host: String
        public var port: Int?
        public var alias: String?
        public var server: String?
    }

    /// Resolves the destination like ssh would: the vault (by alias, as the desktop ssh_config include names its
    /// servers) first, then `HostName`/`User`/`Port` from the user's config. A user typed on the command line wins.
    public func resolved(config: SSHConfigHosts, vault: [String: VaultHostFacts]) -> Resolved {
        if let server = vault[destination] {
            return Resolved(user: user ?? server.user, host: server.host, port: port ?? server.port,
                            alias: destination, server: server.name)
        }
        let settings = config.settings(for: destination)
        let host = settings.hostName ?? destination
        return Resolved(user: user ?? settings.user, host: host, port: port ?? settings.port,
                        alias: host == destination ? nil : destination, server: nil)
    }
}

/// The `Host` blocks of an ssh_config: enough to resolve `HostName`, `User` and `Port` for a title.
public struct SSHConfigHosts: Equatable, Sendable {
    public struct Settings: Equatable, Sendable {
        public var hostName: String?
        public var user: String?
        public var port: Int?
    }

    struct Block: Equatable, Sendable {
        var patterns: [String]
        var settings = Settings()
    }

    var blocks: [Block]

    public init(text: String) {
        var blocks: [Block] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let words = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard words.count == 2 else { continue }
            let key = words[0].lowercased(), value = words[1]
            if key == "host" {
                blocks.append(Block(patterns: value.split(separator: " ").map(String.init)))
                continue
            }
            guard !blocks.isEmpty else { continue }
            switch key {
            case "hostname": blocks[blocks.count - 1].settings.hostName = value
            case "user": blocks[blocks.count - 1].settings.user = value
            case "port": blocks[blocks.count - 1].settings.port = Int(value)
            default: break
            }
        }
        self.blocks = blocks
    }

    /// First value wins, as in ssh.
    public func settings(for host: String) -> Settings {
        var out = Settings()
        for block in blocks where Self.matches(host, block.patterns) {
            out.hostName = out.hostName ?? block.settings.hostName
            out.user = out.user ?? block.settings.user
            out.port = out.port ?? block.settings.port
        }
        if let name = out.hostName { out.hostName = name.replacingOccurrences(of: "%h", with: host) }
        return out
    }

    static func matches(_ host: String, _ patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), host) { return false }
            } else if glob(pattern, host) {
                matched = true
            }
        }
        return matched
    }

    /// `*` and `?` globbing.
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
}
