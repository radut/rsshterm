import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The environment and shell of a local terminal tab.
public enum ShellEnvironment {
    public static let termProgram = "rSshTerm"

    /// `base` (the app's own environment) with what every local tab gets: TERM=xterm-256color, COLORTERM=truecolor,
    /// TERM_PROGRAM=rSshTerm and its version, SSH_AUTH_SOCK pointing at the built-in agent (when it runs; else the
    /// user's own agent stays), and a UTF-8 LANG when no locale is set (apps started from the Dock have none).
    public static func make(base: [String: String], agentSocket: String?, appVersion: String) -> [String: String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = termProgram
        env["TERM_PROGRAM_VERSION"] = appVersion
        if let agentSocket { env["SSH_AUTH_SOCK"] = agentSocket }
        if env["LANG"] == nil, env["LC_ALL"] == nil, env["LC_CTYPE"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// $SHELL when it is an absolute path to an executable, else the login shell from the user database, else /bin/sh.
    public static func userShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"], shell.hasPrefix("/"), access(shell, X_OK) == 0 { return shell }
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if shell.hasPrefix("/"), access(shell, X_OK) == 0 { return shell }
        }
        return "/bin/sh"
    }

    /// The executable for `command`: itself when it contains a slash, else the first match on `path`.
    public static func resolve(_ command: String, path: String?) -> String? {
        if command.contains("/") { return access(command, X_OK) == 0 ? command : nil }
        for dir in (path ?? "/usr/bin:/bin").split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(command)"
            var info = stat()
            if access(candidate, X_OK) == 0, stat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
                return candidate
            }
        }
        return nil
    }
}
