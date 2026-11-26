import Foundation

/// The commander's keys per platform. Function keys work on both (Midnight Commander's layout); the Mac adds the
/// Finder's Cmd shortcuts, Linux the file managers' Ctrl ones.
public enum CommanderKeymap {
    public static func bindings(for platform: Platform) -> [KeyChord: CommanderAction] {
        var map: [KeyChord: CommanderAction] = [
            KeyChord(key: "f3", modifiers: []): .view,
            KeyChord(key: "f4", modifiers: []): .edit,
            KeyChord(key: "f5", modifiers: []): .copy,
            KeyChord(key: "f6", modifiers: []): .move,
            KeyChord(key: "f6", modifiers: .shift): .rename,
            KeyChord(key: "f7", modifiers: []): .makeFolder,
            KeyChord(key: "f8", modifiers: []): .delete,
            KeyChord(key: "tab", modifiers: []): .switchPane,
            KeyChord(key: "enter", modifiers: []): .open,
            KeyChord(key: "insert", modifiers: []): .toggleSelection,
            KeyChord(key: "space", modifiers: []): .toggleSelection,
            KeyChord(key: "u", modifiers: .control): .swapPanes,
            KeyChord(key: "=", modifiers: .option): .sameFolder,
        ]
        switch platform {
        case .macOS:
            map[KeyChord(key: "up", modifiers: .command)] = .goUp
            map[KeyChord(key: "down", modifiers: .command)] = .open
            map[KeyChord(key: "backspace", modifiers: .command)] = .delete
            map[KeyChord(key: "r", modifiers: .command)] = .refresh
            map[KeyChord(key: "a", modifiers: .command)] = .selectAll
            map[KeyChord(key: ".", modifiers: [.command, .shift])] = .toggleHidden
            map[KeyChord(key: "n", modifiers: [.command, .shift])] = .makeFolder
            map[KeyChord(key: "c", modifiers: [.command, .option])] = .copy
        case .linux:
            map[KeyChord(key: "backspace", modifiers: [])] = .goUp
            map[KeyChord(key: "up", modifiers: .option)] = .goUp
            map[KeyChord(key: "delete", modifiers: [])] = .delete
            map[KeyChord(key: "f2", modifiers: [])] = .rename
            map[KeyChord(key: "r", modifiers: .control)] = .refresh
            map[KeyChord(key: "a", modifiers: .control)] = .selectAll
            map[KeyChord(key: "h", modifiers: .control)] = .toggleHidden
            map[KeyChord(key: "n", modifiers: [.control, .shift])] = .makeFolder
        }
        return map
    }

    /// The bottom button bar, MC style: key, action, title.
    public static var buttonBar: [(key: String, action: CommanderAction, title: String)] {
        [("F3", .view, "View"), ("F4", .edit, "Edit"), ("F5", .copy, "Copy"), ("F6", .move, "Move"),
         ("F7", .makeFolder, "New Folder"), ("F8", .delete, "Delete")]
    }
}
