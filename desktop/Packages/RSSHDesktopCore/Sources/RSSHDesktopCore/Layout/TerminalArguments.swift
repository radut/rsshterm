import Foundation
import RSSHKit

/// The command line a default terminal is started with (x-terminal-emulator, xdg-terminal-exec, Nautilus "Open in
/// Terminal", a launcher): `-e cmd args…`, `--working-directory DIR`, `-T title`, and `ssh://user@host:port`.
public struct TerminalArguments: Equatable, Sendable {
    /// What to run instead of the login shell (argv), from `-e`, `-x` or `--`.
    public var command: [String]?
    /// Where the shell or command starts (`--working-directory`); nil: the home directory.
    public var directory: String?
    /// The tab title (`-T`, `--title`).
    public var title: String?
    /// An `ssh://` URL to open.
    public var url: SSHURL?

    public init(command: [String]? = nil, directory: String? = nil, title: String? = nil, url: SSHURL? = nil) {
        self.command = command
        self.directory = directory
        self.title = title
        self.url = url
    }

    /// True when nothing was asked: the app opens as usual (a local shell, or the restored windows).
    public var isEmpty: Bool { command == nil && directory == nil && url == nil && title == nil }

    /// The local tab these arguments ask for (nil for an `ssh://` URL, which needs the vault or Quick Connect).
    public var localContent: PaneContent? {
        guard url == nil, command != nil || directory != nil || title != nil else { return nil }
        return .localShell(command: command, directory: directory)
    }

    public static func parse(_ arguments: [String]) throws(TerminalArgumentError) -> TerminalArguments {
        var result = TerminalArguments()
        var index = arguments.startIndex
        func value(_ flag: String) throws(TerminalArgumentError) -> String {
            index += 1
            guard index < arguments.endIndex else { throw .missingValue(flag) }
            return arguments[index]
        }
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "-e", "-x", "--execute", "--":
                let rest = Array(arguments[(index + 1)...])
                guard !rest.isEmpty else { throw .missingValue(argument) }
                result.command = commandLine(rest)
                return result
            case "--working-directory", "--workdir", "-w":
                result.directory = try value(argument)
            case "-T", "--title", "-t":
                result.title = try value(argument)
            default:
                if let dir = argument.stripping(prefix: "--working-directory=") ?? argument.stripping(prefix: "--workdir=") {
                    result.directory = dir
                } else if let title = argument.stripping(prefix: "--title=") {
                    result.title = title
                } else if argument.lowercased().hasPrefix("ssh://") {
                    guard let url = SSHURL(argument) else { throw .badURL(argument) }
                    result.url = url
                } else {
                    throw .unknown(argument)
                }
            }
            index += 1
        }
        if let dir = result.directory, dir.isEmpty { result.directory = nil }
        return result
    }

    /// `-e "vim notes.txt"` (one word with spaces, as xterm takes it) runs through the shell; separate words are argv.
    private static func commandLine(_ words: [String]) -> [String] {
        if words.count == 1, words[0].contains(where: \.isWhitespace) { return ["/bin/sh", "-c", words[0]] }
        return words
    }
}

public enum TerminalArgumentError: Error, Equatable, LocalizedError {
    case missingValue(String)
    case badURL(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .missingValue(let flag): "\(flag) needs a value"
        case .badURL(let text): "not an ssh:// URL: \(text)"
        case .unknown(let argument): "unknown argument: \(argument)"
        }
    }
}

/// `ssh://[user[;params]@]host[:port][/]` (draft-ietf-secsh-scp-sftp-ssh-uri), as browsers, Finder and
/// x-scheme-handler/ssh pass it.
public struct SSHURL: Hashable, Sendable {
    public let username: String?
    public let host: String
    public let port: Int?

    public init(username: String?, host: String, port: Int?) {
        self.username = username
        self.host = host
        self.port = port
    }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("ssh://") else { return nil }
        var rest = Substring(trimmed.dropFirst("ssh://".count))
        if let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = rest[..<slash] }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            let raw = rest[..<at].split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            user = raw.removingPercentEncoding ?? raw
            rest = rest[rest.index(after: at)...]
            guard let u = user, !u.isEmpty, !u.contains(where: { $0.isWhitespace || $0 == ":" }) else { return nil }
        }
        var host: Substring
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
        } else {
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            host = parts[0]
            portText = parts.count == 2 ? parts[1] : nil
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "/" }) else { return nil }
        var port: Int?
        if let portText {
            guard let p = Int(portText), (1...65535).contains(p) else { return nil }
            port = p
        }
        self.init(username: user, host: String(host), port: port)
    }

    /// What opening the URL does: a saved server with that user, host and port (host and port when the URL has no
    /// user); else Quick Connect with the address; else (no user) `ssh` in a local tab, which takes the user from
    /// ~/.ssh/config.
    public func opening(in servers: [Server]) -> SSHURLOpening {
        let wantedPort = port ?? 22
        let match = servers.first { server in
            server.host.caseInsensitiveCompare(host) == .orderedSame && server.port == wantedPort
                && (username.map { $0 == server.username } ?? true)
        }
        if let match { return .server(match.id) }
        if let username { return .quickConnect(QuickAddress(username: username, host: host, port: port)) }
        return .command(["ssh"] + (port.map { ["-p", String($0)] } ?? []) + ["--", host])
    }
}

public enum SSHURLOpening: Hashable, Sendable {
    case server(UUID)
    case quickConnect(QuickAddress)
    case command([String])
}

private extension String {
    func stripping(prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}
