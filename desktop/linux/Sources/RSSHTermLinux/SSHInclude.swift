import Foundation

/// The one line that makes plain `ssh <alias>` (and scp, rsync, git) use the vault: `Include <generated config>` at
/// the top of ~/.ssh/config, above any Host or Match block (inside one it would only apply there).
public enum SSHInclude {
    static let comment = "# Added by rSshTerm: vault servers as ssh hosts"

    /// The path as written in the Include line: `~/…` inside the home directory, else quoted absolute.
    public static func spelling(of configPath: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if configPath.hasPrefix(prefix) { return "~/" + configPath.dropFirst(prefix.count) }
        return "\"\(configPath)\""
    }

    /// True when a top-level Include (before the first Host/Match) names the generated config.
    public static func isInstalled(in text: String, configPath: String, home: String) -> Bool {
        let wanted = normalized(configPath, home: home)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (keyword, value) = split(line)
            switch keyword {
            case "host", "match": return false
            case "include":
                let paths = value.split(whereSeparator: \.isWhitespace).map {
                    normalized($0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), home: home)
                }
                if paths.contains(wanted) { return true }
            default: continue
            }
        }
        return false
    }

    /// `text` with the Include (and a comment saying who added it) on top.
    public static func adding(to text: String, configPath: String, home: String) -> String {
        "\(comment)\nInclude \(spelling(of: configPath, home: home))\n\n" + text
    }

    /// Adds the Include to `<home>/.ssh/config` unless it is there: ~/.ssh 0700, the file 0600, written atomically.
    public static func install(home: String, configPath: String) throws {
        let fm = FileManager.default
        let sshDir = "\(home)/.ssh"
        let file = "\(sshDir)/config"
        if !fm.fileExists(atPath: sshDir) {
            try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let current = fm.fileExists(atPath: file) ? try String(contentsOfFile: file, encoding: .utf8) : ""
        guard !isInstalled(in: current, configPath: configPath, home: home) else { return }
        try Data(adding(to: current, configPath: configPath, home: home).utf8).write(to: URL(fileURLWithPath: file),
                                                                                  options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }

    private static func split(_ line: String) -> (String, String) {
        guard let end = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line.lowercased(), "")
        }
        let keyword = line[..<end].lowercased()
        let rest = line[end...].drop { $0 == " " || $0 == "\t" || $0 == "=" }
        return (keyword, String(rest))
    }

    private static func normalized(_ path: String, home: String) -> String {
        path.hasPrefix("~/") ? home + "/" + path.dropFirst(2) : path
    }
}
