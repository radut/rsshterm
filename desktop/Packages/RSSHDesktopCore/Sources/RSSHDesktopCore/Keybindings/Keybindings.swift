import Foundation

/// Everything a key can trigger in the desktop app.
public enum DesktopAction: Hashable, Sendable {
    case newTab, newWindow, closePane
    case splitRight, splitDown
    case focus(Direction)
    case nextPane, previousPane
    /// Moves the focused pane's divider that way.
    case resizePane(Direction)
    /// 1…8 select that tab, 9 the last.
    case selectTab(Int)
    case nextTab, previousTab
    case moveTabLeft, moveTabRight
    case hostSearch, commandPalette
    /// Broadcast input (iTerm2's Shell › Broadcast Input): back to the current session only; all panes of the
    /// window's tabs (toggles off again); the current tab; the visible panes; add/remove the focused pane by hand;
    /// the picker (presets + checkboxes). See `BroadcastState`.
    case broadcastCurrentOnly, broadcastAllTabs, broadcastCurrentTab, broadcastVisible, toggleBroadcastSession
    case broadcastPicker
    case equalizePanes, toggleZoom
    /// Edit the current tab's title (empty restores the automatic one).
    case renameTab
    /// The jump switcher: every open shell, then vault servers for a new session.
    case jumpSwitcher
    /// App commands (the Mac's File, Shell and Vault menus): terminal font size, the tool windows, the vault.
    case biggerFont, smallerFont, resetFontSize
    case showServers, quickConnect, showFiles, openFileManagerHere, lockVault, showKeys
    /// Moving panes and tabs (iTerm2's Session › Move Session, Ghostty's and GNOME Terminal's detach): the focused
    /// pane to its own tab or window, the selected tab to its own window, every window's tabs into this one, the
    /// "pick a target" mode (the pane is marked; click or arrow to a pane, Enter drops it), swapping with the
    /// neighbouring pane.
    case movePaneToNewTab, movePaneToNewWindow, moveTabToNewWindow, mergeAllWindows, movePaneMode
    case swapPane(Direction)
    /// Duplicate Tab / Pane / Window: the same servers and commands (local shells in the same folder) in new sessions.
    case duplicateTab, duplicatePane, duplicateWindow
    /// Window › Edit Window Title.
    case editWindowTitle

    /// The moves and duplicates, which the app runs over all its windows.
    public static let moveCommands: [DesktopAction] =
        [.movePaneToNewTab, .movePaneToNewWindow, .moveTabToNewWindow, .mergeAllWindows, .movePaneMode]
        + Direction.allCases.map { .swapPane($0) }
        + [.duplicateTab, .duplicatePane, .duplicateWindow, .editWindowTitle]

    /// The app commands, which open UI or change settings and never touch the layout.
    public static let appCommands: [DesktopAction] =
        [.biggerFont, .smallerFont, .resetFontSize, .showServers, .quickConnect, .showFiles, .openFileManagerHere,
         .lockVault, .showKeys]

    public static let allCases: [DesktopAction] =
        [.newTab, .newWindow, .closePane, .splitRight, .splitDown]
        + Direction.allCases.map { .focus($0) }
        + [.nextPane, .previousPane]
        + Direction.allCases.map { .resizePane($0) }
        + (1...9).map { .selectTab($0) }
        + [.nextTab, .previousTab, .moveTabLeft, .moveTabRight, .hostSearch, .commandPalette, .equalizePanes, .toggleZoom]
        + [.renameTab, .jumpSwitcher]
        + [.broadcastCurrentOnly, .broadcastAllTabs, .broadcastCurrentTab, .broadcastVisible, .toggleBroadcastSession,
           .broadcastPicker]
        + appCommands
        + moveCommands

    /// The name in the config file: `newTab`, `focusLeft`, `selectTab3`, ...
    public var identifier: String {
        switch self {
        case .newTab: "newTab"
        case .newWindow: "newWindow"
        case .closePane: "closePane"
        case .splitRight: "splitRight"
        case .splitDown: "splitDown"
        case .focus(let d): "focus" + d.rawValue.capitalized
        case .nextPane: "nextPane"
        case .previousPane: "previousPane"
        case .resizePane(let d): "resizePane" + d.rawValue.capitalized
        case .moveTabLeft: "moveTabLeft"
        case .moveTabRight: "moveTabRight"
        case .selectTab(let n): "selectTab\(n)"
        case .nextTab: "nextTab"
        case .previousTab: "previousTab"
        case .hostSearch: "hostSearch"
        case .commandPalette: "commandPalette"
        case .broadcastCurrentOnly: "broadcastCurrentOnly"
        case .broadcastAllTabs: "broadcastAllTabs"
        case .broadcastCurrentTab: "broadcastCurrentTab"
        case .broadcastVisible: "broadcastVisible"
        case .toggleBroadcastSession: "toggleBroadcastSession"
        case .broadcastPicker: "broadcastPicker"
        case .equalizePanes: "equalizePanes"
        case .toggleZoom: "toggleZoom"
        case .renameTab: "renameTab"
        case .jumpSwitcher: "jumpSwitcher"
        case .biggerFont: "biggerFont"
        case .smallerFont: "smallerFont"
        case .resetFontSize: "resetFontSize"
        case .showServers: "showServers"
        case .quickConnect: "quickConnect"
        case .showFiles: "showFiles"
        case .openFileManagerHere: "openFileManagerHere"
        case .lockVault: "lockVault"
        case .showKeys: "showKeys"
        case .movePaneToNewTab: "movePaneToNewTab"
        case .movePaneToNewWindow: "movePaneToNewWindow"
        case .moveTabToNewWindow: "moveTabToNewWindow"
        case .mergeAllWindows: "mergeAllWindows"
        case .movePaneMode: "movePaneMode"
        case .swapPane(let d): "swapPane" + d.rawValue.capitalized
        case .duplicateTab: "duplicateTab"
        case .duplicatePane: "duplicatePane"
        case .duplicateWindow: "duplicateWindow"
        case .editWindowTitle: "editWindowTitle"
        }
    }

    public init?(identifier: String) {
        if identifier == "toggleBroadcastInput" { // the name before the broadcast modes
            self = .broadcastCurrentTab
            return
        }
        guard let action = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = action
    }
}

/// The `keybindings` section of the desktop config: action identifier → chords; an empty list unbinds the action.
public struct KeybindingConfig: Codable, Equatable, Sendable {
    public var keybindings: [String: [String]]

    public init(keybindings: [String: [String]] = [:]) { self.keybindings = keybindings }
}

/// The key table: each chord triggers at most one action; an action may have several chords.
public struct Keybindings: Equatable, Sendable {
    private let table: [KeyChord: DesktopAction]

    public init(_ table: [KeyChord: DesktopAction]) { self.table = table }

    public func action(for chord: KeyChord) -> DesktopAction? { table[chord] }

    /// The chords of `action`, sorted by their text (for menus and the palette).
    public func chords(for action: DesktopAction) -> [KeyChord] {
        table.filter { $0.value == action }.map(\.key).sorted { $0.description < $1.description }
    }

    /// The defaults with `overrides` applied: each listed action gets exactly its chords (none = unbound); a chord
    /// given to an action is taken from whatever action had it.
    public func applying(_ overrides: [String: [String]]) throws(KeybindingError) -> Keybindings {
        var newTable = table
        for (identifier, texts) in overrides.sorted(by: { $0.key < $1.key }) {
            guard let action = DesktopAction(identifier: identifier) else { throw .unknownAction(identifier) }
            var chords: [KeyChord] = []
            for text in texts { chords.append(try KeyChord(parsing: text)) }
            newTable = newTable.filter { $0.value != action }
            for chord in chords { newTable[chord] = action }
        }
        return Keybindings(newTable)
    }

    /// Actions with no default chord (menu only): "current only" (Cmd/Ctrl+Shift+I toggles broadcast off), "visible
    /// panes", and on Linux the app commands (its own menus and dialogs) and the modes whose Mac chords have no free Ctrl+Shift equivalent.
    public static func menuOnly(_ platform: Platform) -> Set<DesktopAction> {
        switch platform {
        case .macOS: [.broadcastCurrentOnly, .broadcastVisible, .mergeAllWindows, .duplicatePane, .duplicateWindow,
                      .editWindowTitle]
        case .linux: Set([.broadcastCurrentOnly, .broadcastVisible, .broadcastCurrentTab, .toggleBroadcastSession,
                          .mergeAllWindows, .duplicateTab, .duplicatePane, .duplicateWindow, .editWindowTitle]
                         + DesktopAction.appCommands)
        }
    }

    /// The defaults of docs/research/desktop.md §2.2. macOS: Command, like iTerm2 and Ghostty (⌘K opens host
    /// search). Linux: Ctrl+Shift, like GNOME Terminal, Ghostty and Terminator, so plain Ctrl+letter stays the
    /// shell's; Ctrl+1…9 switch tabs (free in terminals) and Alt+arrows move focus.
    public static func defaults(for platform: Platform) -> Keybindings {
        func chord(_ text: String) -> KeyChord { try! KeyChord(parsing: text) }
        let pairs: [(String, DesktopAction)]
        switch platform {
        case .macOS:
            pairs = [
                ("cmd+t", .newTab), ("cmd+n", .newWindow), ("cmd+w", .closePane),
                ("cmd+d", .splitRight), ("cmd+shift+d", .splitDown),
                ("cmd+alt+left", .focus(.left)), ("cmd+alt+right", .focus(.right)),
                ("cmd+alt+up", .focus(.up)), ("cmd+alt+down", .focus(.down)),
                ("cmd+]", .nextPane), ("cmd+[", .previousPane),
                ("cmd+ctrl+left", .resizePane(.left)), ("cmd+ctrl+right", .resizePane(.right)),
                ("cmd+ctrl+up", .resizePane(.up)), ("cmd+ctrl+down", .resizePane(.down)),
                ("cmd+shift+]", .nextTab), ("ctrl+tab", .nextTab),
                ("cmd+shift+[", .previousTab), ("ctrl+shift+tab", .previousTab),
                ("cmd+shift+left", .moveTabLeft), ("cmd+shift+right", .moveTabRight),
                ("cmd+k", .hostSearch), ("cmd+shift+p", .commandPalette),
                ("cmd+alt+i", .broadcastCurrentTab), ("cmd+shift+i", .broadcastAllTabs),
                ("cmd+alt+shift+i", .broadcastPicker), ("cmd+ctrl+alt+shift+i", .toggleBroadcastSession), ("cmd+ctrl+=", .equalizePanes),
                ("cmd+shift+enter", .toggleZoom), ("cmd+r", .renameTab), ("cmd+j", .jumpSwitcher),
                ("cmd+=", .biggerFont), ("cmd+-", .smallerFont), ("cmd+0", .resetFontSize),
                ("cmd+shift+s", .showServers), ("cmd+shift+o", .quickConnect), ("cmd+shift+f", .showFiles),
                ("cmd+alt+f", .openFileManagerHere), ("cmd+ctrl+l", .lockVault), ("cmd+alt+shift+k", .showKeys),
                // Moves (iTerm2/Ghostty have no defaults; ⌥⇧ on the new-tab/window keys, ⌥⇧ on the focus arrows)
                ("cmd+alt+shift+t", .movePaneToNewTab), ("cmd+alt+shift+n", .movePaneToNewWindow),
                ("cmd+alt+n", .moveTabToNewWindow), ("cmd+alt+shift+m", .movePaneMode), ("cmd+alt+t", .duplicateTab),
                ("cmd+alt+shift+left", .swapPane(.left)), ("cmd+alt+shift+right", .swapPane(.right)),
                ("cmd+alt+shift+up", .swapPane(.up)), ("cmd+alt+shift+down", .swapPane(.down)),
            ] + (1...9).map { ("cmd+\($0)", .selectTab($0)) }
        case .linux:
            pairs = [
                ("ctrl+shift+t", .newTab), ("ctrl+shift+n", .newWindow), ("ctrl+shift+w", .closePane),
                ("ctrl+shift+e", .splitRight), ("ctrl+shift+o", .splitDown),
                ("alt+left", .focus(.left)), ("alt+right", .focus(.right)),
                ("alt+up", .focus(.up)), ("alt+down", .focus(.down)),
                ("ctrl+shift+]", .nextPane), ("ctrl+shift+[", .previousPane),
                ("ctrl+shift+alt+left", .resizePane(.left)), ("ctrl+shift+alt+right", .resizePane(.right)),
                ("ctrl+shift+alt+up", .resizePane(.up)), ("ctrl+shift+alt+down", .resizePane(.down)),
                ("ctrl+pagedown", .nextTab), ("ctrl+tab", .nextTab),
                ("ctrl+pageup", .previousTab), ("ctrl+shift+tab", .previousTab),
                ("ctrl+shift+pageup", .moveTabLeft), ("ctrl+shift+pagedown", .moveTabRight),
                ("ctrl+shift+k", .hostSearch), ("ctrl+shift+p", .commandPalette),
                ("ctrl+shift+i", .broadcastAllTabs), ("ctrl+shift+alt+i", .broadcastPicker), ("ctrl+shift+alt+=", .equalizePanes),
                ("ctrl+shift+x", .toggleZoom), ("ctrl+shift+r", .renameTab), ("ctrl+shift+j", .jumpSwitcher),
                ("ctrl+shift+alt+t", .movePaneToNewTab), ("ctrl+shift+alt+n", .movePaneToNewWindow),
                ("ctrl+shift+alt+d", .moveTabToNewWindow), ("ctrl+shift+alt+m", .movePaneMode),
                ("alt+shift+left", .swapPane(.left)), ("alt+shift+right", .swapPane(.right)),
                ("alt+shift+up", .swapPane(.up)), ("alt+shift+down", .swapPane(.down)),
            ] + (1...9).map { ("ctrl+\($0)", .selectTab($0)) }
        }
        precondition(Set(pairs.map(\.0)).count == pairs.count, "a default chord is bound twice")
        return Keybindings(Dictionary(pairs.map { (chord($0.0), $0.1) }) { first, _ in first })
    }
}
