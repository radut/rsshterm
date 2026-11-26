import Foundation
import RSSHKit

/// One open terminal for the jump switcher (Cmd+J / Ctrl+Shift+J): every pane of every window and tab.
public struct OpenShell: Equatable, Sendable {
    public let id: PaneID
    public let title: String
    /// The SSH host, nil for a local shell.
    public let host: String?
    /// The working directory when known (OSC 7).
    public let directory: String?
    /// When the pane last had focus: most recent first on an empty query.
    public let lastUsed: Date

    public init(id: PaneID, title: String, host: String?, directory: String?, lastUsed: Date) {
        self.id = id
        self.title = title
        self.host = host
        self.directory = directory
        self.lastUsed = lastUsed
    }
}

public enum JumpSwitcherResult: Equatable, Sendable {
    /// Jump there: focus its window, select its tab, focus the pane.
    case shell(PaneID)
    /// "New session on <server>": Enter a new tab, Shift+Enter a split.
    case newSession(UUID)
    /// A remote desktop of the vault: open its screen in a tab (Shift+Enter: a split).
    case openScreen(UUID)
}

/// Ranks the jump switcher's rows: open shells first (by fuzzy score; most recently used first when the query is
/// empty or scores tie), then vault servers as new sessions (the host search ranking).
public enum JumpSwitcher {
    public static func results(query: String, openShells: [OpenShell], servers: [Server], groups: [ServerGroup] = [],
                               remoteDesktops: [RemoteDesktop] = [], limit: Int = 50) -> [JumpSwitcherResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let scored: [(OpenShell, Int)] = openShells.compactMap { shell in
            let fields = [shell.title, shell.host ?? "", shell.directory ?? ""].filter { !$0.isEmpty }
            var total = 0
            for word in words {
                guard let best = fields.compactMap({ FuzzyMatcher.score(word, in: $0) }).max() else { return nil }
                total += best
            }
            return (shell, total)
        }
        let shells = scored.sorted {
            $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastUsed > $1.0.lastUsed
        }.map { JumpSwitcherResult.shell($0.0.id) }
        let sessions = HostSearchIndex(servers: servers, groups: groups).search(query, limit: max(limit, 0))
            .map { JumpSwitcherResult.newSession($0.server.id) }
        let screens = words.isEmpty ? [] : RemoteDesktopSearch.search(query, desktops: remoteDesktops, groups: groups,
                                                                      servers: servers)
            .map { JumpSwitcherResult.openScreen($0.id) }
        return Array((shells + sessions + screens).prefix(max(limit, 0)))
    }
}
