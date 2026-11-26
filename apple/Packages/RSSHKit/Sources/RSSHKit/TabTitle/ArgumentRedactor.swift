import Foundation

/// Takes secrets out of a command line before a tab shows it: values of password/token/secret/key flags, `-p` of
/// the programs where it means a password (mysql, sshpass), `NAME_TOKEN=` assignments, `user:pass@` in URLs,
/// `user:pass` of `curl -u`, secret headers (`Authorization:`, `X-Api-Key:`) and `Bearer`/`Basic` credentials.
/// Wrappers (`sudo`, `env`, `time`, ...) pass the rules on to the program they run. Conservative: a false positive
/// only hides a harmless word. The same rules as rsshd's `probe.SanitizeArgs` (rsshd/internal/probe/sanitize.go).
public enum ArgumentRedactor {
    public static let mask = "•••"

    /// Words in a flag, header or variable name that mark its value as secret.
    static let secretWords = ["pass", "pwd", "token", "secret", "key", "auth", "credential", "cookie", "session"]
    /// Programs whose `-p` (attached or separate) is a password, not a port.
    static let shortPPassword: Set<String> = ["mysql", "mariadb", "mysqldump", "mysqladmin", "mysqlimport",
                                              "mysqlshow", "mysqlcheck", "sshpass"]
    /// Of those, the ones whose bare `-p` prompts (no value follows).
    static let attachedOnly: Set<String> = ["mysql", "mariadb", "mysqldump", "mysqladmin", "mysqlimport",
                                            "mysqlshow", "mysqlcheck"]
    /// Programs that run another program.
    static let wrappers: Set<String> = ["sudo", "doas", "env", "time", "nohup", "nice", "exec", "command", "builtin",
                                        "stdbuf", "timeout", "watch", "xargs", "ionice", "chrt", "taskset",
                                        "caffeinate"]
    /// Wrapper options that take a value (`sudo -u root`, `nice -n 5`).
    static let wrapperValueOptions: Set<String> = ["-u", "-g", "-n", "-s", "-k", "-C", "-D", "-h", "-p", "-r", "-t",
                                                   "-U", "-c", "-o", "-e", "-i", "-L", "-I"]
    /// Options whose value is `user:password`.
    static let userPassOptions: Set<String> = ["-u", "--user", "--proxy-user", "-U"]

    public static func redact(program: String, _ args: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(args.count)
        redact(name: CommandFacts.programName(program).lowercased(), args[...], into: &out)
        return out
    }

    /// Redacts the arguments of a whole command line (`argv[0]` is kept).
    public static func redact(argv: [String]) -> [String] {
        guard let first = argv.first else { return [] }
        return [first] + redact(program: first, Array(argv.dropFirst()))
    }

    private static func redact(name: String, _ args: ArraySlice<String>, into out: inout [String]) {
        if wrappers.contains(name) {
            var i = args.startIndex
            while i < args.endIndex {
                let arg = args[i]
                if arg == "--" {
                    out.append(arg); i += 1
                } else if arg.hasPrefix("-") {
                    out.append(redactInline(arg))
                    if wrapperValueOptions.contains(arg), i + 1 < args.endIndex {
                        out.append(args[i + 1]); i += 1
                    }
                    i += 1
                } else if CommandFacts.isAssignment(arg) {
                    out.append(redactInline(arg)); i += 1
                } else {
                    break
                }
            }
            guard i < args.endIndex else { return }
            out.append(args[i])
            redact(name: CommandFacts.programName(args[i]).lowercased(), args[(i + 1)...], into: &out)
            return
        }
        var hideNext = false
        var userPassNext = false
        for arg in args {
            if hideNext {
                out.append(mask); hideNext = false; continue
            }
            if userPassNext {
                out.append(maskUserPass(arg)); userPassNext = false; continue
            }
            if shortPPassword.contains(name), arg.hasPrefix("-p"), !arg.hasPrefix("--") {
                if arg == "-p" {
                    hideNext = !attachedOnly.contains(name)
                    out.append(arg)
                } else {
                    out.append("-p" + mask)
                }
                continue
            }
            if arg.hasPrefix("-") {
                if let eq = arg.firstIndex(of: "="), eq != arg.startIndex {
                    let flag = String(arg[..<eq])
                    if isSecretName(flag) {
                        out.append(flag + "=" + mask)
                    } else if userPassOptions.contains(flag) {
                        out.append(flag + "=" + maskUserPass(String(arg[arg.index(after: eq)...])))
                    } else {
                        out.append(redactInline(arg))
                    }
                    continue
                }
                if isSecretName(arg) {
                    out.append(arg); hideNext = true; continue
                }
                if userPassOptions.contains(arg) {
                    out.append(arg); userPassNext = true; continue
                }
            }
            out.append(redactInline(arg))
        }
    }

    static func isSecretName(_ flag: String) -> Bool {
        let lower = flag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard lower.count > 1, !lower.hasSuffix("file"), !lower.hasSuffix("path") else { return false }
        return secretWords.contains { lower.contains($0) }
    }

    static func maskUserPass(_ value: String) -> String {
        guard let colon = value.firstIndex(of: ":") else { return value }
        return String(value[...colon]) + mask
    }

    /// `NAME_TOKEN=value`, `Header-With-Secret: value`, `scheme://user:pass@host`, `Bearer xyz` in one argument.
    static func redactInline(_ arg: String) -> String {
        if !arg.hasPrefix("-"), CommandFacts.isAssignment(arg), let eq = arg.firstIndex(of: "=") {
            let name = String(arg[..<eq])
            if isSecretName(name) { return name + "=" + mask }
        }
        if let colon = arg.range(of: ": "), colon.lowerBound != arg.startIndex {
            let header = String(arg[..<colon.lowerBound])
            if !header.contains(" "), !header.contains("/"),
               isSecretName(header) || header.lowercased() == "authorization" {
                return header + ": " + mask
            }
        }
        var text = arg
        if let scheme = text.range(of: "://") {
            let rest = text[scheme.upperBound...]
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = rest[..<authorityEnd]
            if let at = authority.lastIndex(of: "@"), let colon = authority[..<at].firstIndex(of: ":") {
                text.replaceSubrange(text.index(after: colon)..<at, with: mask)
            }
        }
        for scheme in ["Bearer ", "Basic ", "token "] {
            if let range = text.range(of: scheme, options: .caseInsensitive), range.upperBound < text.endIndex {
                text.replaceSubrange(range.upperBound..<text.endIndex, with: mask)
                break
            }
        }
        return text
    }
}
