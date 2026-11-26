/// One row of the shortcut help sheet: the keys, what the shell does, and the bytes sent (readable).
public struct WordEditingShortcut: Hashable, Sendable, Identifiable {
    public let keys: String
    public let action: String
    public let sends: String
    public var id: String { keys }
}

/// The hardware keyboard shortcuts active under some settings, built from `HardwareKeyMap` so the sheet cannot drift
/// from what the keys really send.
public enum WordEditingShortcuts {
    private struct Row {
        let keys: String
        let key: TerminalKey
        let modifiers: HardwareModifiers
        let action: String
    }

    private static let rows: [Row] = [
        Row(keys: "⌥←", key: .left, modifiers: .option, action: "Word left"),
        Row(keys: "⌥→", key: .right, modifiers: .option, action: "Word right"),
        Row(keys: "⌘←", key: .left, modifiers: .command, action: "Start of line"),
        Row(keys: "⌘→", key: .right, modifiers: .command, action: "End of line"),
        Row(keys: "⌥⌫", key: .backspace, modifiers: .option, action: "Delete word before cursor"),
        Row(keys: "⌘⌫", key: .backspace, modifiers: .command, action: "Delete to start of line"),
        Row(keys: "fn⌫ / ⌦", key: .delete, modifiers: [], action: "Delete character after cursor"),
        Row(keys: "⌥fn⌫ / ⌥⌦", key: .delete, modifiers: .option, action: "Delete word after cursor"),
        Row(keys: "⌘fn⌫ / ⌘⌦", key: .delete, modifiers: .command, action: "Delete to end of line"),
        Row(keys: "⌃←", key: .left, modifiers: .control, action: "Word left (where inputrc maps it)"),
        Row(keys: "⌃→", key: .right, modifiers: .control, action: "Word right (where inputrc maps it)"),
        Row(keys: "⌃⌫", key: .backspace, modifiers: .control, action: "Delete word before cursor"),
        Row(keys: "⌃⌦", key: .delete, modifiers: .control, action: "Delete word after cursor"),
    ]

    /// The rows that send something under `settings`, with the action adjusted where the preset changes it.
    public static func list(_ settings: WordEditingSettings) -> [WordEditingShortcut] {
        rows.compactMap { row in
            guard let bytes = HardwareKeyMap.bytes(for: row.key, modifiers: row.modifiers, settings: settings,
                                                   applicationCursor: false) else { return nil }
            return WordEditingShortcut(keys: row.keys, action: action(row, bytes, settings), sends: readable(bytes))
        }
    }

    private static func action(_ row: Row, _ bytes: [UInt8], _ settings: WordEditingSettings) -> String {
        if row.modifiers == .control, row.key == .backspace, bytes == [0x08] { return "Backspace (^H)" }
        if row.modifiers == .control, row.key == .delete, settings.ctrlDelete == .escD { return "Delete word after cursor" }
        if row.modifiers == .control, row.key == .delete { return "Delete word after cursor (where inputrc maps it)" }
        if settings.preset == .linux, row.modifiers == .option, row.key == .left || row.key == .right {
            return row.action + " (where inputrc maps it)"
        }
        if settings.preset == .linux, row.modifiers == .option, row.key == .delete {
            return "Alt+Delete (where inputrc maps it)"
        }
        return row.action
    }

    /// `ESC b`, `^W`, `ESC [3;5~`: how the bytes read in a shell's bindkey or inputrc.
    public static func readable(_ bytes: [UInt8]) -> String {
        var parts: [String] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                let rest = bytes[(index + 1)...]
                if rest.first == 0x5B {   // CSI: print the whole sequence as text
                    parts.append("ESC " + String(decoding: rest, as: UTF8.self))
                    break
                }
                parts.append("ESC")
            } else if byte == 0x7F {
                parts.append("DEL")
            } else if byte < 0x20 {
                parts.append("^" + String(UnicodeScalar(byte + 0x40)))
            } else {
                parts.append(String(UnicodeScalar(byte)))
            }
            index += 1
        }
        return parts.joined(separator: " ")
    }
}
