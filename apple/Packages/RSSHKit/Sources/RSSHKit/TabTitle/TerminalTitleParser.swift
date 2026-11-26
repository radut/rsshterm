import Foundation

/// What a shell reported with OSC 7 (`file://host/path`).
public struct DirectoryReport: Equatable, Sendable, Codable {
    public var host: String?
    public var path: String

    public init(host: String?, path: String) {
        self.host = host
        self.path = path
    }
}

/// Reads the facts a shell puts in the window title (OSC 0/2).
///
/// - `user@host: path` / `user@host:path`: a prompt (the Debian/Ubuntu bash default, zsh/fish themes, and the
///   rSSH shell integration's precmd title).
/// - `user@host › command line`: a command started (the rSSH shell integration's preexec title).
///
/// Anything else (`htop`, vim's own title) is opaque: it only fills `{title}`.
public enum TerminalTitleParser {
    public enum Parsed: Equatable, Sendable {
        case prompt(user: String, host: String, cwd: String)
        case running(user: String, host: String, commandLine: String)
    }

    /// The separator the shell integration puts between `user@host` and the command line.
    public static let runningSeparator = " › "

    public static func parse(_ title: String) -> Parsed? {
        let text = title.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: runningSeparator) {
            guard let (user, host) = userHost(String(text[..<range.lowerBound])) else { return nil }
            let command = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : .running(user: user, host: host, commandLine: command)
        }
        guard let colon = text.firstIndex(of: ":"), let (user, host) = userHost(String(text[..<colon])) else {
            return nil
        }
        let path = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return nil }
        return .prompt(user: user, host: host, cwd: path)
    }

    /// OSC 7's `file://host/path` (percent-encoded).
    public static func parseDirectoryURI(_ uri: String) -> DirectoryReport? {
        guard uri.lowercased().hasPrefix("file://") else { return nil }
        let rest = uri.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash])
        let path = String(rest[slash...])
        return DirectoryReport(host: host.isEmpty ? nil : host, path: path.removingPercentEncoding ?? path)
    }

    private static func userHost(_ text: String) -> (String, String)? {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let user = String(parts[0]), host = String(parts[1])
        let allowed: (Character) -> Bool = { $0.isLetter || $0.isNumber || "._-".contains($0) }
        guard !user.isEmpty, !host.isEmpty, user.allSatisfy(allowed), host.allSatisfy(allowed) else { return nil }
        return (user, host)
    }
}

/// Splits a command line the way a POSIX shell would for display: quotes and backslashes, no expansion.
public enum ShellWords {
    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for c in line {
            if escaped {
                current.append(c); escaped = false; inWord = true; continue
            }
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"" { escaped = true } else { current.append(c) }
                continue
            }
            switch c {
            case "\\": escaped = true; inWord = true
            case "'", "\"": quote = c; inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            default: current.append(c); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}

/// The program and its arguments, from an argv or a typed command line.
public struct CommandFacts: Equatable, Sendable {
    public var process: String?
    public var args: [String]

    /// argv as the kernel has it: argv[0] is the program (a login shell's "-zsh" becomes "zsh").
    public init(argv: [String]) {
        guard let first = argv.first else {
            process = nil; args = []; return
        }
        process = Self.programName(first)
        args = Array(argv.dropFirst())
    }

    /// A typed command line: leading `NAME=value` assignments are skipped, the rest as argv.
    public init(commandLine: String) {
        var words = ShellWords.split(commandLine)
        while let first = words.first, Self.isAssignment(first) { words.removeFirst() }
        self.init(argv: words)
    }

    static func programName(_ argv0: String) -> String {
        var name = argv0.split(separator: "/").last.map(String.init) ?? argv0
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        return word[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
