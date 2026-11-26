/// Modifier keys held on a hardware keyboard.
public struct HardwareModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = HardwareModifiers(rawValue: 1 << 0)
    public static let control = HardwareModifiers(rawValue: 1 << 1)
    public static let option = HardwareModifiers(rawValue: 1 << 2)
    public static let command = HardwareModifiers(rawValue: 1 << 3)

    /// The xterm view of shift, option (alt) and control; Cmd has no xterm meaning.
    var xterm: KeyModifiers {
        var mods = KeyModifiers()
        if contains(.shift) { mods.insert(.shift) }
        if contains(.option) { mods.insert(.alt) }
        if contains(.control) { mods.insert(.ctrl) }
        return mods
    }
}

/// A hardware key press -> the bytes to send, or nil to leave the key to the terminal view (typing, Cmd shortcuts,
/// Page Up/Down scrolling). Pure: no UI, no state.
///
/// - `.delete` is the forward delete key (Fn-Delete on an Apple keyboard).
/// - Plain arrows, Home and End follow DECCKM (`applicationCursor`); with modifiers they use xterm's `ESC[1;mX`.
public enum HardwareKeyMap {
    public static func bytes(for key: TerminalKey, modifiers: HardwareModifiers, optionSide: OptionSide = .unknown,
                             settings: WordEditingSettings, applicationCursor: Bool) -> [UInt8]? {
        switch key {
        case .left, .right:
            return horizontal(key, modifiers, settings, applicationCursor)
        case .up, .down, .home, .end:
            guard !modifiers.contains(.command) else { return nil }
            return KeyEncoder.encode(key, modifiers: modifiers.xterm, applicationCursor: applicationCursor)
        case .backspace:
            return backspace(modifiers, settings)
        case .delete:
            return forwardDelete(modifiers, settings)
        case .character(let ch):
            return meta(ch, modifiers, optionSide, settings)
        default:
            return nil
        }
    }

    /// Ctrl+Backspace under `settings`.
    public static func ctrlBackspace(_ settings: WordEditingSettings) -> [UInt8] {
        settings.ctrlBackspace == .ctrlW ? [0x17] : [0x08]
    }

    /// Ctrl+Delete (forward) under `settings`.
    public static func ctrlDelete(_ settings: WordEditingSettings) -> [UInt8] {
        settings.ctrlDelete == .escD ? [0x1B, 0x64] : KeyEncoder.encode(.delete, modifiers: .ctrl)
    }

    // MARK: - keys

    private static func horizontal(_ key: TerminalKey, _ mods: HardwareModifiers, _ settings: WordEditingSettings,
                                   _ applicationCursor: Bool) -> [UInt8]? {
        let natural = settings.preset == .natural
        let left = key == .left
        if mods == .command {
            return natural ? (left ? WordEdit.lineStart : .lineEnd).bytes(settings) : nil
        }
        if mods.contains(.command) { return nil }
        if mods == .option, natural {
            return (left ? WordEdit.wordLeft : .wordRight).bytes(settings)
        }
        // Ctrl+arrows are always xterm (`ESC[1;5D`), as are Option (Alt) arrows in the Linux preset.
        return KeyEncoder.encode(key, modifiers: mods.xterm, applicationCursor: applicationCursor)
    }

    private static func backspace(_ mods: HardwareModifiers, _ settings: WordEditingSettings) -> [UInt8]? {
        switch mods {
        case []: return [0x7F]
        case .shift: return [0x7F]
        case .option: return [0x1B, 0x7F]
        case .control: return ctrlBackspace(settings)
        case .command: return settings.preset == .natural ? WordEdit.deleteToLineStart.bytes(settings) : nil
        default: return nil
        }
    }

    private static func forwardDelete(_ mods: HardwareModifiers, _ settings: WordEditingSettings) -> [UInt8]? {
        let natural = settings.preset == .natural
        switch mods {
        case []: return KeyEncoder.encode(.delete)
        case .option: return natural ? WordEdit.deleteWordForward.bytes(settings)
                                     : KeyEncoder.encode(.delete, modifiers: .alt)
        case .control: return ctrlDelete(settings)
        case .command: return natural ? WordEdit.deleteToLineEnd.bytes(settings) : nil
        default: return mods.contains(.command) ? nil : KeyEncoder.encode(.delete, modifiers: mods.xterm)
        }
    }

    /// Option+letter as Meta: ESC + the letter without Option (shift kept). Ctrl or Cmd with it: left to the view.
    private static func meta(_ ch: Character, _ mods: HardwareModifiers, _ side: OptionSide,
                             _ settings: WordEditingSettings) -> [UInt8]? {
        guard mods.contains(.option), mods.isDisjoint(with: [.control, .command]), settings.isMeta(side) else {
            return nil
        }
        return [0x1B] + Array(String(ch).utf8)
    }
}
