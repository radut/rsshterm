import Foundation

/// The command lines the app sends to a server for rsshd. Each one is wrapped in `sh -c '…'` so it means the same
/// under bash, zsh, fish or csh, and puts the per-user install folders on PATH (an exec channel gets no login PATH).
public enum RsshdCommands {
    static let path = #"PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH""#

    /// The control channel (exec, no PTY). Exits 127 when rsshd is not installed, which the app reads as "absent".
    public static let rpc = "sh -c '\(path); command -v rsshd >/dev/null 2>&1 || exit 127; exec rsshd rpc'"

    /// The server check behind the status sheet: OS, apt, where rsshd is, and `rsshd doctor --json`. Always exits
    /// 0 (doctor exits 1 when something is missing, and the output is what matters).
    public static let check = "sh -c '\(path); echo \"uname:$(uname -s)\"; "
        + "command -v apt-get >/dev/null 2>&1 && echo apt:yes; "
        + "if command -v rsshd >/dev/null 2>&1; then echo \"rsshd:$(command -v rsshd)\"; rsshd doctor --json 2>/dev/null; fi; "
        + "exit 0'"

    /// Typed into the PTY shell as its first input until the app can send pty-req + exec (Citadel gap, design §5.3).
    /// The leading space keeps it out of shell history where HISTCONTROL ignores such lines. nil for an id that is
    /// not a plain token, since it is pasted into a command line.
    public static func typedAttach(id: String) -> String? {
        guard isSafeID(id) else { return nil }
        return " exec sh -c '\(path); exec rsshd attach \(id)'\r"
    }

    /// Attaches one of the user's own tmux/screen sessions (`RsshdForeign.attach`), every word quoted.
    public static func typedForeign(_ argv: [String]) -> String? {
        guard !argv.isEmpty else { return nil }
        return " exec " + argv.map(quote).joined(separator: " ") + "\r"
    }

    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            && id.unicodeScalars.allSatisfy(\.isASCII)
    }

    /// POSIX single quotes: ' becomes '\''.
    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
