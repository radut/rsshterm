import Foundation

/// The user's changes to the default keybindings, in the config file's form (`{"keybindings": {"newTab":
/// ["cmd+alt+t"], "hostSearch": []}}`): action identifier → its chords, an empty list unbinds it. Only changed actions
/// are listed, so new defaults in later builds still arrive. Every edit returns a new value.
public struct KeybindingOverrides: Codable, Equatable, Sendable {
    public let bindings: [String: [String]]

    public static let none = KeybindingOverrides()

    public init(_ bindings: [String: [String]] = [:]) { self.bindings = bindings }

    public init(from decoder: any Decoder) throws {
        bindings = try KeybindingConfig(from: decoder).keybindings
    }

    public func encode(to encoder: any Encoder) throws {
        try KeybindingConfig(keybindings: bindings).encode(to: encoder)
    }

    /// The defaults with these changes. An entry this build cannot read (an unknown action, a bad chord) is skipped,
    /// so one bad line never loses the rest.
    public func keybindings(for platform: Platform) -> Keybindings {
        let readable = bindings.filter { identifier, texts in
            DesktopAction(identifier: identifier) != nil && texts.allSatisfy { (try? KeyChord(parsing: $0)) != nil }
        }
        let defaults = Keybindings.defaults(for: platform)
        return (try? defaults.applying(readable)) ?? defaults
    }

    public func isCustomized(_ action: DesktopAction) -> Bool { bindings[action.identifier] != nil }

    /// The other action that has `chord` now, if any: assigning it to `action` would take it away from that one.
    public func conflict(for chord: KeyChord, assigningTo action: DesktopAction, platform: Platform) -> DesktopAction? {
        guard let owner = keybindings(for: platform).action(for: chord), owner != action else { return nil }
        return owner
    }

    /// `action` gets exactly `chords` (none = unbound). Any other action holding one of them loses it, and that is
    /// saved too. An action left with its default chords is dropped from the list.
    public func setting(_ action: DesktopAction, to chords: [KeyChord], platform: Platform) -> KeybindingOverrides {
        let current = keybindings(for: platform)
        let taken = Set(chords)
        var next = bindings
        for owner in Set(chords.compactMap(current.action(for:))) where owner != action {
            next[owner.identifier] = current.chords(for: owner).filter { !taken.contains($0) }.map(\.description)
        }
        next[action.identifier] = chords.map(\.description)
        let defaults = Keybindings.defaults(for: platform)
        return KeybindingOverrides(next.filter { identifier, texts in
            guard let a = DesktopAction(identifier: identifier) else { return true } // keep what a newer build wrote
            let chords = texts.compactMap { try? KeyChord(parsing: $0) }
            return Set(chords) != Set(defaults.chords(for: a)) || chords.count != texts.count
        })
    }

    /// `action` back to its default chords, taken back from any action that had them.
    public func resetting(_ action: DesktopAction, platform: Platform) -> KeybindingOverrides {
        setting(action, to: Keybindings.defaults(for: platform).chords(for: action), platform: platform)
    }
}

extension KeyChord {
    /// Whether the chord can be a shortcut without eating typed text: Command or Control (a Mac's Option types
    /// characters such as ´ and ©), Alt also on Linux, or a function key.
    public func isUsableShortcut(on platform: Platform) -> Bool {
        if key.count > 1, key.hasPrefix("f"), Int(key.dropFirst()) != nil { return true }
        switch platform {
        case .macOS: return modifiers.contains(.command) || modifiers.contains(.control)
        case .linux: return modifiers.contains(.control) || modifiers.contains(.option) || modifiers.contains(.command)
        }
    }

    private static let macKeys: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "enter": "↩", "return": "↩", "tab": "⇥", "space": "Space",
        "escape": "⎋", "esc": "⎋", "backspace": "⌫", "delete": "⌦", "pageup": "⇞", "pagedown": "⇟", "home": "↖",
        "end": "↘", "insert": "Ins",
    ]
    private static let linuxKeys: [String: String] = [
        "pageup": "Page Up", "pagedown": "Page Down", "escape": "Esc", "esc": "Esc", "backspace": "Backspace",
        "enter": "Enter", "return": "Enter",
    ]

    /// How a menu or the Shortcuts list shows it: `⇧⌘D` on a Mac (Apple's ⌃⌥⇧⌘ order), `Ctrl+Shift+T` on Linux.
    public func displayText(on platform: Platform) -> String {
        let isFunction = key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil
        switch platform {
        case .macOS:
            let order: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            let name = Self.macKeys[key] ?? key.uppercased()
            return order.filter { modifiers.contains($0.0) }.map(\.1).joined() + name
        case .linux:
            let order: [(Modifiers, String)] = [(.command, "Super"), (.control, "Ctrl"), (.option, "Alt"), (.shift, "Shift")]
            let name = Self.linuxKeys[key] ?? (key.count == 1 || isFunction ? key.uppercased() : key.capitalized)
            return (order.filter { modifiers.contains($0.0) }.map(\.1) + [name]).joined(separator: "+")
        }
    }
}

extension DesktopAction {
    /// Where the action sits in a shortcuts list.
    public enum Category: String, CaseIterable, Sendable {
        case tabs = "Tabs", panes = "Panes", moving = "Move & Duplicate", broadcast = "Broadcast Input", font = "Font", app = "Servers & Vault"
    }

    public var category: Category {
        switch self {
        case .newTab, .newWindow, .selectTab, .nextTab, .previousTab, .moveTabLeft, .moveTabRight, .renameTab: .tabs
        case .closePane, .splitRight, .splitDown, .focus, .nextPane, .previousPane, .resizePane, .equalizePanes,
             .toggleZoom: .panes
        case .movePaneToNewTab, .movePaneToNewWindow, .moveTabToNewWindow, .mergeAllWindows, .movePaneMode, .swapPane,
             .duplicateTab, .duplicatePane, .duplicateWindow, .editWindowTitle: .moving
        case .broadcastCurrentOnly, .broadcastAllTabs, .broadcastCurrentTab, .broadcastVisible, .toggleBroadcastSession,
             .broadcastPicker: .broadcast
        case .biggerFont, .smallerFont, .resetFontSize: .font
        case .hostSearch, .commandPalette, .jumpSwitcher, .showServers, .quickConnect, .showFiles, .openFileManagerHere,
             .lockVault, .showKeys: .app
        }
    }

    /// The name in menus and the Shortcuts list.
    public var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newWindow: "New Window"
        case .closePane: "Close Pane"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .focus(let d): "Focus Pane " + d.rawValue.capitalized
        case .nextPane: "Next Pane"
        case .previousPane: "Previous Pane"
        case .resizePane(let d): "Move Divider " + d.rawValue.capitalized
        case .selectTab(let n): n == 9 ? "Select Last Tab" : "Select Tab \(n)"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .moveTabLeft: "Move Tab Left"
        case .moveTabRight: "Move Tab Right"
        case .hostSearch: "Search Servers"
        case .commandPalette: "Command Palette"
        case .broadcastCurrentOnly: "Send Input to Current Session Only"
        case .broadcastAllTabs: "Broadcast to All Panes in All Tabs"
        case .broadcastCurrentTab: "Broadcast to All Panes in Current Tab"
        case .broadcastVisible: "Broadcast to Visible Panes"
        case .toggleBroadcastSession: "Toggle Broadcast to Current Session"
        case .broadcastPicker: "Choose Broadcast Panes"
        case .equalizePanes: "Equalize Panes"
        case .toggleZoom: "Zoom Pane"
        case .renameTab: "Rename Tab"
        case .jumpSwitcher: "Jump to Shell or Server"
        case .biggerFont: "Bigger Font"
        case .smallerFont: "Smaller Font"
        case .resetFontSize: "Default Font Size"
        case .showServers: "Servers"
        case .quickConnect: "Quick Connect"
        case .showFiles: "Files"
        case .openFileManagerHere: "Open File Manager Here"
        case .lockVault: "Lock Vault"
        case .showKeys: "Keys & Passwords"
        case .movePaneToNewTab: "Move Pane to New Tab"
        case .movePaneToNewWindow: "Move Pane to New Window"
        case .moveTabToNewWindow: "Move Tab to New Window"
        case .mergeAllWindows: "Merge All Windows"
        case .movePaneMode: "Move Pane…"
        case .swapPane(let d): "Swap Pane " + (d == .up ? "Above" : d == .down ? "Below" : d.rawValue.capitalized)
        case .duplicateTab: "Duplicate Tab"
        case .duplicatePane: "Duplicate Pane"
        case .duplicateWindow: "Duplicate Window"
        case .editWindowTitle: "Edit Window Title"
        }
    }
}
