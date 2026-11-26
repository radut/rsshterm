import Foundation

/// Everything the Tab Titles settings page shows besides the fields: presets, the placeholder reference, the
/// preview tabs and the help on where facts come from. One copy for iOS, macOS and Linux.
public enum TabTitleCatalog {
    public struct Preset: Equatable, Sendable, Identifiable {
        public var name: String
        public var template: String
        public var id: String { name }
    }

    public struct PlaceholderHelp: Equatable, Sendable, Identifiable {
        public var name: String
        public var summary: String
        public var example: String
        public var token: String { "{\(name)}" }
        public var id: String { name }
    }

    public struct Sample: Equatable, Sendable, Identifiable {
        public var name: String
        public var facts: TabTitleFacts
        public var id: String { name }
    }

    public struct HelpSection: Equatable, Sendable, Identifiable {
        public var title: String
        public var body: String
        public var id: String { title }
    }

    public static let titlePresets: [Preset] = [
        Preset(name: "Name", template: TabTitleSettings.defaultTitle),
        Preset(name: "user@host", template: "{custom|user@host|host}"),
        Preset(name: "Host", template: "{custom|host}"),
        Preset(name: "Program", template: "{custom|process|server|host}"),
    ]

    public static let subtitlePresets: [Preset] = [
        Preset(name: "Minimal", template: "{host}"),
        Preset(name: "Descriptive", template: TabTitleSettings.defaultSubtitle),
        Preset(name: "Process first", template: "{process} · {user}@{host}"),
        Preset(name: "Folder", template: "{user}@{host}:{cwdShort}"),
        Preset(name: "None", template: ""),
    ]

    public static let placeholders: [PlaceholderHelp] = [
        PlaceholderHelp(name: "custom", summary: "The name you gave the tab (Rename, Cmd+R). Clear it to go back to automatic.",
                        example: "deploy"),
        PlaceholderHelp(name: "server", summary: "The vault server's name.", example: "Web 1"),
        PlaceholderHelp(name: "user", summary: "The user logged in on the host.", example: "root"),
        PlaceholderHelp(name: "host", summary: "The host name or address.", example: "web1.example.com"),
        PlaceholderHelp(name: "alias", summary: "The name typed after ssh, before ssh_config or the vault resolved it.",
                        example: "web"),
        PlaceholderHelp(name: "process", summary: "The program running in the foreground; empty at the shell prompt.",
                        example: "vim"),
        PlaceholderHelp(name: "args", summary: "Its arguments; passwords and tokens are hidden.",
                        example: "/etc/nginx/nginx.conf"),
        PlaceholderHelp(name: "cwd", summary: "The current folder, ~ for home.", example: "~/projects/site"),
        PlaceholderHelp(name: "cwdShort", summary: "The current folder's last two parts.", example: "…/nginx/sites-enabled"),
        PlaceholderHelp(name: "title", summary: "The title the program set (OSC 0/2).", example: "htop"),
        PlaceholderHelp(name: "index", summary: "The tab's number (Cmd/Ctrl+1…9).", example: "2"),
    ]

    /// Syntax help under the reference list.
    public static let syntaxHelp: [HelpSection] = [
        HelpSection(title: "{name}", body: "The value, or nothing. {args:30} caps it at 30 characters."),
        HelpSection(title: "{a|b|user@host}", body: "The first choice that has every value; \"text\" is a fixed choice."),
        HelpSection(title: "{process? · {process}}", body: "The part after ? only when process has a value."),
        HelpSection(title: "{!process? · {cwdShort}}", body: "The part after ? only when process is empty."),
        HelpSection(title: "{{ and }}", body: "Literal braces."),
    ]

    public static let samples: [Sample] = [
        Sample(name: "Local shell, idle", facts: TabTitleFacts(user: "me", host: "laptop", cwd: "/home/me/projects",
                                                               home: "/home/me", index: 1)),
        Sample(name: "ssh running vim", facts: TabTitleFacts(user: "root", host: "web1.example.com", alias: "web1",
                                                             process: "vim", args: ["/etc/nginx/nginx.conf"],
                                                             cwd: "/etc/nginx", home: "/root", index: 2)),
        Sample(name: "rSshD session", facts: TabTitleFacts(user: "deploy", host: "app1", server: "App 1",
                                                           cwd: "/var/log", home: "/home/deploy", index: 3)),
        Sample(name: "Renamed tab", facts: TabTitleFacts(custom: "deploy", user: "ci", host: "build1", process: "make",
                                                         args: ["-j8", "release"], cwd: "/srv/build",
                                                         index: 4)),
    ]

    public static let sourcesHelp: [HelpSection] = [
        HelpSection(title: "rSshD sessions", body: """
            A session kept by rSshD reports its program, arguments and folder from tmux and the server's process \
            table: the most exact source, live while the tab is open.
            """),
        HelpSection(title: "Shell integration", body: """
            A few lines in the server's ~/.bashrc, ~/.zshrc or fish config send the folder (OSC 7) and, while a \
            command runs, "user@host › command" as the title. Works on any server, without rSshD. Install it from a \
            session's … menu (Shell Integration), or copy the snippet for bash, zsh or fish below.
            """),
        HelpSection(title: "Prompt titles", body: """
            Many shells already set "user@host: folder" as the title (Debian and Ubuntu's bash): the tab reads the \
            folder from it.
            """),
        HelpSection(title: "Local tabs (desktop)", body: """
            The app reads the program in the foreground of the tab's terminal. When it is ssh, its target \
            (user@host, -l, -p, aliases from ~/.ssh/config and the vault) names the tab until the server reports more.
            """),
        HelpSection(title: "Vault servers", body: """
            A tab opened from the vault knows the server's name, user and host from the start.
            """),
    ]

    /// `token` put into `text` at `cursor` (clamped); returns the new text and the cursor after the token.
    public static func insert(_ token: String, into text: String, at cursor: Int) -> (String, Int) {
        let position = max(0, min(cursor, text.count))
        let index = text.index(text.startIndex, offsetBy: position)
        var out = text
        out.insert(contentsOf: token, at: index)
        return (out, position + token.count)
    }
}
