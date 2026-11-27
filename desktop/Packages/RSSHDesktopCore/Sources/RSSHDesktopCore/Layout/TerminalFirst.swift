import Foundation

// The desktop app is a terminal first, like Terminal.app, GNOME Terminal and iTerm2: it opens a local shell at
// once, and servers, the vault and files come on demand. These rules are shared by the Mac and Linux apps.

/// What the app opens at launch: the saved windows (Restore Windows on, something saved), else one window with a
/// local shell. Never nothing, and never the servers window.
public enum LaunchPlan: Equatable, Sendable {
    case restore([Window])
    case localShell

    public static func make(restoreSession: Bool, saved: Session?) -> LaunchPlan {
        guard restoreSession, let windows = saved?.windows.filter({ !$0.tabs.isEmpty }), !windows.isEmpty else {
            return .localShell
        }
        return .restore(windows)
    }

    /// The windows to open, in order.
    public var windows: [Window] {
        switch self {
        case .restore(let windows): windows
        case .localShell: [Window(tabs: [Tab(pane: Pane(content: .localShell()))])]
        }
    }

    /// True when a restored pane needs the vault (a server or a remote desktop): only then does launch ask to unlock.
    /// A plain local shell never waits for the vault.
    public var needsVault: Bool {
        windows.contains { $0.tabs.contains { $0.root.panes.contains { $0.content.needsVault } } }
    }
}

extension PaneContent {
    /// Vault servers and remote desktops need the unlocked vault; a local shell or command does not.
    public var needsVault: Bool {
        switch self {
        case .localShell: false
        case .ssh, .remoteDesktop: true
        }
    }
}

/// A terminal request from anywhere: a terminal window, the servers window, the Dock, a menu.
public enum TerminalRequest: Equatable, Sendable {
    /// Cmd+T / Ctrl+Shift+T: a local shell tab.
    case newLocalTab
    /// Cmd+N / Ctrl+Shift+N: a window with a local shell.
    case newLocalWindow
    /// A server, screen or command opened from the servers window, a menu or host search.
    case open(PaneContent)
}

/// Where a request goes: a tab of an existing terminal window, or a new window.
public enum TerminalTarget<WindowID: Hashable & Sendable>: Hashable, Sendable {
    case tab(in: WindowID)
    case newWindow
}

/// Routes terminal requests: new tabs and opened servers go to the frontmost terminal window, a new window when
/// there is none; a new window is always new.
public enum TerminalRouting {
    /// `frontToBack`: the terminal windows, frontmost first (other windows, such as Servers, are not in it).
    public static func target<ID: Hashable & Sendable>(for request: TerminalRequest, frontToBack: [ID]) -> TerminalTarget<ID> {
        switch request {
        case .newLocalWindow: .newWindow
        case .newLocalTab, .open: frontToBack.first.map { .tab(in: $0) } ?? .newWindow
        }
    }

    /// What the new pane runs.
    public static func content(of request: TerminalRequest) -> PaneContent {
        switch request {
        case .newLocalTab, .newLocalWindow: .localShell()
        case .open(let content): content
        }
    }

    /// The request a key or menu action makes, when it makes one (newTab, newWindow).
    public static func request(for action: DesktopAction) -> TerminalRequest? {
        switch action {
        case .newTab: .newLocalTab
        case .newWindow: .newLocalWindow
        default: nil
        }
    }
}

/// When the app ends.
public enum AppLifecycle {
    /// After the last terminal window closes: the Mac keeps running (the Dock icon opens a new window), as every Mac
    /// app does; Linux quits, unless the servers window is still open.
    public static func quitsAfterLastTerminalWindow(platform: Platform, serversWindowOpen: Bool) -> Bool {
        switch platform {
        case .macOS: false
        case .linux: !serversWindowOpen
        }
    }

    /// The Dock icon clicked (or the app activated again) with no terminal window: open one with a local shell.
    public static func reopenOpensTerminal(terminalWindows: Int) -> Bool { terminalWindows == 0 }
}
