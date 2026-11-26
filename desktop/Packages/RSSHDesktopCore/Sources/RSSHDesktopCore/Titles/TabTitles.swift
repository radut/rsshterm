import Foundation
import RSSHKit

/// The live title facts of one pane, kept by the UI from its terminal's callbacks:
///
/// - `terminalTitle`: OSC 0/2 (VTE `termprop-changed`/`window-title-changed`, SwiftTerm `setTerminalTitle`);
/// - `directory`: OSC 7 (VTE `current-directory-uri`, SwiftTerm `hostCurrentDirectoryUpdate`);
/// - `local`: `LocalPTY.localFacts(...)` or `ForegroundProcess.localFacts(masterFD:...)` for local panes, polled
///   about once a second while the tab is visible and after output;
/// - `daemon`: rsshd's `Session.pane` / `pane` events for rsshd sessions.
public struct PaneTitleState: Equatable, Sendable {
    public var terminalTitle: String?
    public var directory: DirectoryReport?
    public var local: LocalProcessFacts?
    public var daemon: PaneReport?

    public init(terminalTitle: String? = nil, directory: DirectoryReport? = nil, local: LocalProcessFacts? = nil,
                daemon: PaneReport? = nil) {
        self.terminalTitle = terminalTitle
        self.directory = directory
        self.local = local
        self.daemon = daemon
    }

    /// OSC 7's `file://host/path`; anything else clears the report.
    public mutating func setDirectoryURI(_ uri: String?) {
        directory = uri.flatMap(TerminalTitleParser.parseDirectoryURI)
    }
}

/// Names the desktop's tabs: the vault, the user's ssh_config and the title settings, applied to a `Tab` and its
/// panes' live states. Tab bar: `label.title` bold with `label.subtitle` under it (or `label.singleLine` when
/// `settings.singleLine`); window title: `label.windowTitle` of the selected tab.
public struct TabTitleContext: Sendable {
    public var settings: TabTitleSettings
    public let servers: [Server]
    /// Remote desktop entries, so a screen pane is titled by its entry (name, host, user).
    public let remoteDesktops: [RemoteDesktop]
    public let sshContext: SSHResolveContext

    /// `sshConfigText`: the user's ~/.ssh/config (and ~/.config/rssh/ssh_config), for aliases typed in local tabs.
    public init(servers: [Server], remoteDesktops: [RemoteDesktop] = [], sshConfigText: String = "",
                settings: TabTitleSettings = TabTitleSettings()) {
        self.settings = settings
        self.servers = servers
        self.remoteDesktops = remoteDesktops
        var vault: [String: VaultHostFacts] = [:]
        let aliases = SSHConfigGenerator.aliases(for: servers)
        let hostCounts = Dictionary(servers.map { ($0.host, 1) }, uniquingKeysWith: +)
        for server in servers {
            let facts = Self.facts(server)
            if let alias = aliases[server.id] { vault[alias] = facts }
            if hostCounts[server.host] == 1, vault[server.host] == nil { vault[server.host] = facts }
        }
        sshContext = SSHResolveContext(config: SSHConfigHosts(text: sshConfigText), vault: vault)
    }

    static func facts(_ server: Server) -> VaultHostFacts {
        VaultHostFacts(name: server.name, host: server.host, user: server.username, port: server.port)
    }

    /// Everything known about `pane` (`custom`: the tab's manual name, `index`: 1-based).
    public func sources(for pane: Pane, custom: String?, index: Int, state: PaneTitleState) -> TabTitleSources {
        var sources = TabTitleSources(custom: custom, index: index, sshContext: sshContext,
                                      terminalTitle: state.terminalTitle, directory: state.directory,
                                      daemon: state.daemon)
        switch pane.content {
        case .ssh(let id):
            sources.vault = servers.first { $0.id == id }.map(Self.facts)
        case .localShell:
            sources.local = state.local
        case .remoteDesktop(let id):
            sources.vault = remoteDesktops.first { $0.id == id }.map {
                VaultHostFacts(name: $0.name, host: $0.host, user: $0.username, port: $0.port)
            }
        }
        return sources
    }

    /// The two lines of `tab` (its focused pane speaks for it); `index` is the tab's 1-based position.
    public func label(for tab: Tab, index: Int, states: [PaneID: PaneTitleState]) -> TabTitleLabel {
        let pane = tab.focusedPane
        let facts = sources(for: pane, custom: tab.title, index: index, state: states[pane.id] ?? PaneTitleState())
            .facts()
        return settings.label(for: facts)
    }
}
