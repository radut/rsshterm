/// RFB key events carry X11 keysyms (RFC 6143 7.5.4). Text and the special keys of a hardware or on-screen
/// keyboard map to them here, the same on iOS, macOS and Linux.
public enum X11Keysym {
    public static let backspace: UInt32 = 0xff08
    public static let tab: UInt32 = 0xff09
    public static let returnKey: UInt32 = 0xff0d
    public static let escape: UInt32 = 0xff1b
    public static let home: UInt32 = 0xff50
    public static let left: UInt32 = 0xff51
    public static let up: UInt32 = 0xff52
    public static let right: UInt32 = 0xff53
    public static let down: UInt32 = 0xff54
    public static let pageUp: UInt32 = 0xff55
    public static let pageDown: UInt32 = 0xff56
    public static let end: UInt32 = 0xff57
    public static let insert: UInt32 = 0xff63
    public static let delete: UInt32 = 0xffff
    public static let shiftLeft: UInt32 = 0xffe1
    public static let controlLeft: UInt32 = 0xffe3
    /// Command on a Mac: macOS Screen Sharing maps Super/Meta to ⌘; Alt to ⌥.
    public static let metaLeft: UInt32 = 0xffe7
    public static let altLeft: UInt32 = 0xffe9
    public static let superLeft: UInt32 = 0xffeb

    /// F1...F35 (0xffbe...).
    public static func function(_ n: Int) -> UInt32? {
        (1...35).contains(n) ? 0xffbe + UInt32(n - 1) : nil
    }

    /// The keysym that types `scalar`: Latin-1 is its own code; "\n" and "\t" are Return and Tab; other
    /// Unicode is 0x01000000 + code point (X11's Unicode keysyms). Control characters other than those type nothing.
    public static func keysym(for scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x0a, 0x0d: returnKey
        case 0x09: tab
        case 0x08, 0x7f: backspace
        case 0x1b: escape
        case 0x20...0x7e, 0xa0...0xff: scalar.value
        case 0x00...0x1f, 0x80...0x9f: nil
        default: 0x0100_0000 + scalar.value
        }
    }

    /// One keysym per typeable scalar of `text`, in order ("\r\n" types one Return).
    public static func keysyms(typing text: String) -> [UInt32] {
        var out: [UInt32] = []
        var lastWasCR = false
        for scalar in text.unicodeScalars {
            defer { lastWasCR = scalar == "\r" }
            if scalar == "\n", lastWasCR { continue }
            if let k = keysym(for: scalar) { out.append(k) }
        }
        return out
    }
}
