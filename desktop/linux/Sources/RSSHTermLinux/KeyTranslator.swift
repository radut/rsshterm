import RSSHDesktopCore

/// GDK's modifier bits (`GdkModifierType`), without the lock keys: Caps Lock and Num Lock never change a chord.
public struct GdkModifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = GdkModifiers(rawValue: 1 << 0)
    public static let control = GdkModifiers(rawValue: 1 << 2)
    public static let alt = GdkModifiers(rawValue: 1 << 3)
    public static let superKey = GdkModifiers(rawValue: 1 << 26)
    public static let meta = GdkModifiers(rawValue: 1 << 28)

    /// Only the bits a chord can hold, from a raw event state.
    public init(state: UInt32) {
        self = GdkModifiers(rawValue: state).intersection([.shift, .control, .alt, .superKey, .meta])
    }
}

/// Turns a GTK key press (keyval + modifier state) into a core `KeyChord`, so `Keybindings` decides what it does.
public enum KeyTranslator {
    public enum ClipboardAction: Equatable, Sendable { case copy, paste }

    /// GDK keyvals of named keys (gdk/gdkkeysyms.h).
    static let named: [UInt32: String] = {
        var table: [UInt32: String] = [
            0xff51: "left", 0xff52: "up", 0xff53: "right", 0xff54: "down",
            0xff55: "pageup", 0xff56: "pagedown", 0xff50: "home", 0xff57: "end",
            0xff0d: "enter", 0xff8d: "enter", 0xff09: "tab", 0xfe20: "tab", 0x20: "space",
            0xff1b: "escape", 0xff08: "backspace", 0xffff: "delete", 0xff63: "insert",
        ]
        for n in 1...12 { table[0xffbe + UInt32(n - 1)] = "f\(n)" }
        return table
    }()

    /// Shift turns these keys into other symbols on a US layout; chords are written with the unshifted key.
    static let unshifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    public static func chord(keyval: UInt32, rawState: UInt32) -> KeyChord? {
        chord(keyval: keyval, modifiers: GdkModifiers(state: rawState))
    }

    public static func chord(keyval: UInt32, modifiers: GdkModifiers) -> KeyChord? {
        guard let key = keyName(keyval) else { return nil }
        var mods: KeyChord.Modifiers = []
        if modifiers.contains(.control) { mods.insert(.control) }
        if modifiers.contains(.alt) { mods.insert(.option) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.superKey) || modifiers.contains(.meta) { mods.insert(.command) }
        return KeyChord(key: key, modifiers: mods)
    }

    /// Ctrl+Shift+C / Ctrl+Shift+V: copy and paste in a terminal (plain Ctrl+C stays the shell's interrupt).
    public static func clipboard(keyval: UInt32, modifiers: GdkModifiers) -> ClipboardAction? {
        guard modifiers == [.control, .shift] else { return nil }
        switch keyName(keyval) {
        case "c": return .copy
        case "v": return .paste
        default: return nil
        }
    }

    static func keyName(_ keyval: UInt32) -> String? {
        if let name = named[keyval] { return name }
        guard keyval > 0x20, keyval < 0x7f, let scalar = Unicode.Scalar(keyval) else { return nil }
        let ch = Character(scalar)
        if let base = unshifted[ch] { return String(base) }
        return String(ch).lowercased()
    }
}
