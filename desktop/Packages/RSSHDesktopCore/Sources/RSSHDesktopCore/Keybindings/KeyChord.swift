import Foundation

public enum KeybindingError: Error, Equatable, Sendable {
    case invalidChord(String)
    case unknownAction(String)
}

/// The desktop platform, for its default keybindings and install paths.
public enum Platform: String, Codable, Sendable {
    case macOS, linux

    public static var current: Platform {
        #if os(macOS)
        .macOS
        #else
        .linux
        #endif
    }
}

/// One key with modifiers, written like `cmd+shift+d` or `ctrl+pagedown`. Keys are lowercase: a letter or digit,
/// a symbol, or a named key (left, right, up, down, pageup, pagedown, home, end, enter, tab, space, escape, f1…f12).
public struct KeyChord: Hashable, Codable, CustomStringConvertible, Sendable {
    public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)

        /// Written order and names.
        static let names: [(Modifiers, String)] = [(.command, "cmd"), (.control, "ctrl"), (.option, "alt"), (.shift, "shift")]
        static let aliases: [String: Modifiers] = [
            "cmd": .command, "command": .command, "super": .command, "meta": .command,
            "ctrl": .control, "control": .control,
            "alt": .option, "opt": .option, "option": .option,
            "shift": .shift,
        ]
    }

    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    static let namedKeys: Set<String> = Set([
        "left", "right", "up", "down", "pageup", "pagedown", "home", "end", "enter", "return", "tab", "space",
        "escape", "esc", "backspace", "delete", "insert",
    ] + (1...12).map { "f\($0)" })

    /// Parses `mod+mod+key`. A chord needs a key; a lone modifier, an unknown modifier or a key with spaces is an
    /// error. `ctrl++` is Ctrl and the plus key.
    public init(parsing text: String) throws(KeybindingError) {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        var parts = lowered.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if lowered.hasSuffix("++") {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let key = parts.popLast(), !key.isEmpty else { throw .invalidChord(text) }
        var modifiers: Modifiers = []
        for name in parts {
            guard let modifier = Modifiers.aliases[name] else { throw .invalidChord(text) }
            modifiers.insert(modifier)
        }
        let isSingle = key.count == 1 && !key.first!.isWhitespace
        guard isSingle || Self.namedKeys.contains(key) else { throw .invalidChord(text) }
        self.init(key: key, modifiers: modifiers)
    }

    public var description: String {
        (Modifiers.names.filter { modifiers.contains($0.0) }.map(\.1) + [key]).joined(separator: "+")
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        try self.init(parsing: text)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
