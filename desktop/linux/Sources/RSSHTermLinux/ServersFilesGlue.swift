import Foundation
import RSSHDesktopCore
import RSSHKit

/// The server sidebar as a flat list of rows (GtkListBox has no sections): a header per section, then its servers
/// unless the section is collapsed.
public enum SidebarRows {
    public enum Row: Equatable, Sendable {
        case header(groupID: UUID?, title: String, count: Int, collapsed: Bool)
        case server(Server, groupID: UUID?)
        case desktop(RemoteDesktop, groupID: UUID?)
    }

    public static func flatten(_ sections: [ServerListModel.Section]) -> [Row] {
        sections.flatMap { section -> [Row] in
            let header = Row.header(groupID: section.groupID, title: section.title, count: section.servers.count,
                                    collapsed: section.isCollapsed)
            return [header] + (section.isCollapsed ? [] : section.servers.map { .server($0, groupID: section.groupID) })
        }
    }

    /// `user@host[:port]` and the server's screens ("RDP · VNC"; without SSH the screens and the host), then the
    /// tags as `#tag`.
    public static func subtitle(_ server: Server, screens: [ScreenService] = []) -> String {
        let names = screens.map(\.shortTitle)
        var text = server.sshEnabled
            ? ([server.username + "@" + server.host + (server.port == 22 ? "" : ":\(server.port)")] + names).joined(separator: " · ")
            : (names + [server.host]).joined(separator: " · ")
        if !server.tags.isEmpty { text += " · " + server.tags.map { "#\($0)" }.joined(separator: " ") }
        return text
    }
}

/// The file panes' columns.
public enum FileRowText {
    public static func size(_ bytes: Int64?, isDirectory: Bool) -> String {
        guard !isDirectory, let bytes else { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.1f %@", value, units[unit])
    }

    /// `ls -l` style: `drwxr-xr-x`.
    public static func mode(_ permissions: UInt32?, isDirectory: Bool) -> String {
        guard let p = permissions else { return "" }
        let bits: [(UInt32, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o040, "r"), (0o020, "w"), (0o010, "x"),
                                           (0o004, "r"), (0o002, "w"), (0o001, "x")]
        return (isDirectory ? "d" : "-") + String(bits.map { p & $0.0 != 0 ? $0.1 : "-" })
    }

    public static func date(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// "Open File Manager Here" from a terminal pane: a local shell opens this computer at its directory (OSC 7, else
/// home); an SSH pane opens its server, at the directory the remote shell reported (a directory reported by this
/// machine is the local ssh process's, not the server's).
public enum OpenHere {
    public struct Target: Equatable, Sendable {
        public let place: FilePlace
        /// nil: the place's own start folder.
        public let path: FilePath?

        public init(place: FilePlace, path: FilePath?) {
            self.place = place
            self.path = path
        }
    }

    public static func target(content: PaneContent, directory: ShellDirectory?, home: String,
                              localHostName: String) -> Target? {
        switch content {
        case .localShell:
            return Target(place: .local, path: directory?.path ?? FilePath(home))
        case .remoteDesktop:
            return nil
        case .ssh(let serverID):
            guard let directory, !directory.isLocal(localHostName: localHostName) else {
                return Target(place: .server(serverID), path: nil)
            }
            return Target(place: .server(serverID), path: directory.path)
        }
    }
}

/// A server's own font and colours over the app's (the editor's per-server font and theme).
public enum TerminalAppearance {
    public struct Resolved: Equatable, Sendable {
        public let font: String
        public let scheme: TerminalColorScheme?
    }

    /// `defaultFont` is a Pango description ("Monospace 11"); the server may replace its family, its size or both.
    public static func resolve(defaultFont: String, server: Server?) -> Resolved {
        let parts = defaultFont.split(separator: " ")
        let defaultSize = parts.last.flatMap { Int($0) }
        let defaultFamily = defaultSize == nil ? defaultFont : parts.dropLast().joined(separator: " ")
        let family = server?.fontFamily.map(TerminalFontCatalog.migratedName) ?? defaultFamily
        let size = server?.fontSize ?? defaultSize
        let font = size.map { "\(family) \($0)" } ?? family
        return Resolved(font: font, scheme: server?.themeID.flatMap(TerminalColorSchemes.scheme(id:)))
    }
}

/// A Quick Connect tab runs OpenSSH with the target (the built-in agent offers the vault keys; a password is typed
/// in the terminal).
public enum QuickConnectCommand {
    public static func argv(_ plan: QuickConnectPlan, via: String = "") -> [String] {
        var argv = ["ssh"]
        let jump = via.trimmingCharacters(in: .whitespaces)
        if !jump.isEmpty { argv += ["-J", jump] }
        if plan.target.port != 22 { argv += ["-p", String(plan.target.port)] }
        return argv + ["\(plan.target.username)@\(plan.target.host)"]
    }
}

/// What a file row carries when dragged inside the app: which pane, which paths. Text so GTK can carry it as a
/// string; files dragged in from the desktop arrive as a file list instead.
public enum PaneDragToken {
    static let prefix = "rsshterm-pane:"

    public static func encode(side: CommanderModel.Side, paths: [FilePath]) -> String {
        prefix + (side == .left ? "left" : "right") + "\n" + paths.map(\.string).joined(separator: "\n")
    }

    public static func decode(_ text: String) -> (side: CommanderModel.Side, paths: [FilePath])? {
        guard text.hasPrefix(prefix) else { return nil }
        let lines = text.dropFirst(prefix.count).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, lines.count > 1 else { return nil }
        let side: CommanderModel.Side
        switch first {
        case "left": side = .left
        case "right": side = .right
        default: return nil
        }
        return (side, lines.dropFirst().map(FilePath.init))
    }

    /// text/uri-list of local files (for the desktop's file manager).
    public static func uriList(_ paths: [FilePath]) -> String {
        paths.map { URL(fileURLWithPath: $0.string).absoluteString + "\r\n" }.joined()
    }
}
