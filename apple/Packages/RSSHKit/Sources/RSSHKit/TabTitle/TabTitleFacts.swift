import Foundation

/// The placeholders a tab title template can use.
public enum TabTitlePlaceholder: String, CaseIterable, Sendable {
    /// The name the user gave the tab (Cmd+R / rename); empty when none.
    case custom
    case user, host
    /// The name typed after `ssh` (`ssh web` -> "web"), before ssh_config or the vault resolved it.
    case alias
    /// The vault server's name.
    case server
    /// The foreground program, empty while the shell waits at its prompt.
    case process
    /// The program's arguments, secrets taken out.
    case args
    case cwd, cwdShort
    /// What the program set with OSC 0/2.
    case title
    /// The tab's position (1-based).
    case index
}

/// What is known about one tab right now. Every field is optional: a template's sections drop what is missing.
public struct TabTitleFacts: Equatable, Sendable, Codable {
    public var custom: String?
    public var server: String?
    public var alias: String?
    public var user: String?
    public var host: String?
    public var process: String?
    /// Arguments as the program got them; `ArgumentRedactor` runs on them before they show.
    public var args: [String]
    public var cwd: String?
    /// The home folder of `user` where the cwd is, for `~`.
    public var home: String?
    public var title: String?
    public var index: Int?

    public init(custom: String? = nil, user: String? = nil, host: String? = nil, server: String? = nil,
                alias: String? = nil, process: String? = nil, args: [String] = [], cwd: String? = nil,
                home: String? = nil, title: String? = nil, index: Int? = nil) {
        self.custom = custom
        self.server = server
        self.alias = alias
        self.user = user
        self.host = host
        self.process = process
        self.args = args
        self.cwd = cwd
        self.home = home
        self.title = title
        self.index = index
    }

    /// The text of one placeholder before any width cap; "" when unknown.
    public func value(_ placeholder: TabTitlePlaceholder) -> String {
        switch placeholder {
        case .custom: return Self.text(custom)
        case .server: return Self.text(server)
        case .alias: return Self.text(alias)
        case .user: return Self.text(user)
        case .host: return Self.text(host)
        case .process: return Self.text(process)
        case .args:
            guard let process = Self.nonEmpty(process) else { return "" }
            return ArgumentRedactor.redact(program: process, args).joined(separator: " ")
        case .cwd: return cwd.map { TitleText.abbreviateHome($0, home: home) } ?? ""
        case .cwdShort: return cwd.map { TitleText.shortPath($0, home: home) } ?? ""
        case .title: return Self.text(title)
        case .index: return index.map(String.init) ?? ""
        }
    }

    private static func text(_ value: String?) -> String {
        nonEmpty(value) ?? ""
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
