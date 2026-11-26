import Foundation

/// A key the user pressed on the extra key row, the chip bar or a hardware keyboard.
public enum TerminalKey: Hashable, Sendable {
    case character(Character)
    case escape, tab, enter, backspace, delete, insert
    case up, down, left, right
    case home, end, pageUp, pageDown
    /// F1 through F16.
    case function(Int)
}

/// Keyboard modifiers, as xterm counts them.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let alt = KeyModifiers(rawValue: 1 << 1)
    public static let ctrl = KeyModifiers(rawValue: 1 << 2)

    /// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    var xtermParameter: Int { 1 + rawValue }
}

/// Turns keys into the bytes an xterm-compatible terminal sends. Pure: no UI, no state.
public enum KeyEncoder {
    static let esc: UInt8 = 0x1B
    static let csi: [UInt8] = [0x1B, 0x5B]   // ESC [
    static let ss3: [UInt8] = [0x1B, 0x4F]   // ESC O

    /// - Parameter applicationCursor: DECCKM is on (the remote app asked for `ESC O A` style arrows).
    public static func encode(_ key: TerminalKey, modifiers: KeyModifiers = [], applicationCursor: Bool = false) -> [UInt8] {
        switch key {
        case .character(let ch): return encodeCharacter(ch, modifiers: modifiers)
        case .escape: return altPrefixed([esc], modifiers)
        case .tab: return modifiers.contains(.shift) ? csi + ascii("Z") : altPrefixed([0x09], modifiers)
        case .enter: return altPrefixed([0x0D], modifiers)
        case .backspace: return altPrefixed([modifiers.contains(.ctrl) ? 0x08 : 0x7F], modifiers)
        case .up: return cursor("A", modifiers, applicationCursor)
        case .down: return cursor("B", modifiers, applicationCursor)
        case .right: return cursor("C", modifiers, applicationCursor)
        case .left: return cursor("D", modifiers, applicationCursor)
        case .home: return cursor("H", modifiers, applicationCursor)
        case .end: return cursor("F", modifiers, applicationCursor)
        case .insert: return tilde(2, modifiers)
        case .delete: return tilde(3, modifiers)
        case .pageUp: return tilde(5, modifiers)
        case .pageDown: return tilde(6, modifiers)
        case .function(let n): return function(n, modifiers)
        }
    }

    /// Text from the on-screen keyboard while modifiers are latched. Ctrl and shift only make sense on one
    /// character; alt (meta) prefixes ESC to whatever was typed. A typed newline is a carriage return.
    public static func encodeTyped(_ text: String, modifiers: KeyModifiers) -> [UInt8] {
        if text.count == 1, let ch = text.first {
            return ch == "\n" ? altPrefixed([0x0D], modifiers) : encodeCharacter(ch, modifiers: modifiers)
        }
        let plain = Array(text.replacingOccurrences(of: "\n", with: "\r").utf8)
        return modifiers.contains(.alt) ? [esc] + plain : plain
    }

    /// Pasted text: newlines become CR and every control character except TAB and CR is dropped (ESC, C1, DEL…),
    /// so pasted text can neither fake keys nor break out of bracketed paste. When the remote enabled bracketed
    /// paste the text is wrapped in `ESC[200~ … ESC[201~`.
    public static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        var safe = String.UnicodeScalarView()
        safe.append(contentsOf: normalised.unicodeScalars.filter(isPasteable))
        let body = Array(String(safe).utf8)
        return bracketed ? csi + ascii("200~") + body + csi + ascii("201~") : body
    }

    static func isPasteable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0D: return true
        case 0x00...0x1F, 0x7F...0x9F: return false
        default: return true
        }
    }

    // MARK: - pieces

    private static func encodeCharacter(_ ch: Character, modifiers: KeyModifiers) -> [UInt8] {
        var base = Array(String(ch).utf8)
        if modifiers.contains(.shift) { base = Array(String(ch).uppercased().utf8) }
        if modifiers.contains(.ctrl), let control = controlByte(for: ch) { base = [control] }
        return altPrefixed(base, modifiers)
    }

    /// The C0 byte Ctrl+<ch> produces, or nil when the combination has no meaning.
    static func controlByte(for ch: Character) -> UInt8? {
        guard let ascii = ch.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7A: return ascii - 0x60                    // a-z
        case 0x40...0x5F: return ascii - 0x40                    // @ A-Z [ \ ] ^ _
        case 0x20, 0x32: return 0x00                             // space, 2
        case 0x33...0x37: return ascii - 0x33 + 0x1B             // 3-7 -> ESC, FS, GS, RS, US
        case 0x2D, 0x2F: return 0x1F                             // - /
        case 0x3F, 0x38: return 0x7F                             // ? 8
        default: return nil
        }
    }

    private static func altPrefixed(_ bytes: [UInt8], _ modifiers: KeyModifiers) -> [UInt8] {
        modifiers.contains(.alt) ? [esc] + bytes : bytes
    }

    /// Arrows, Home, End: `ESC [ A`, `ESC O A` in application mode, `ESC [ 1 ; m A` with modifiers.
    private static func cursor(_ final: Character, _ modifiers: KeyModifiers, _ application: Bool) -> [UInt8] {
        if !modifiers.isEmpty { return csi + ascii("1;\(modifiers.xtermParameter)") + ascii(final) }
        return (application ? ss3 : csi) + ascii(final)
    }

    /// `ESC [ n ~`, or `ESC [ n ; m ~` with modifiers.
    private static func tilde(_ n: Int, _ modifiers: KeyModifiers) -> [UInt8] {
        let params = modifiers.isEmpty ? "\(n)" : "\(n);\(modifiers.xtermParameter)"
        return csi + ascii(params + "~")
    }

    /// F1-F4 are `ESC O P..S` (`ESC [ 1 ; m P..S` with modifiers); F5-F16 are VT220 tilde codes.
    private static func function(_ n: Int, _ modifiers: KeyModifiers) -> [UInt8] {
        let ss3Finals: [Character] = ["P", "Q", "R", "S"]
        let tildeCodes = [15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29]
        switch n {
        case 1...4:
            let final = ss3Finals[n - 1]
            return modifiers.isEmpty ? ss3 + ascii(final) : csi + ascii("1;\(modifiers.xtermParameter)") + ascii(final)
        case 5...16: return tilde(tildeCodes[n - 5], modifiers)
        default: return []
        }
    }

    private static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
    private static func ascii(_ c: Character) -> [UInt8] { Array(String(c).utf8) }
}
