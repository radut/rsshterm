import RSSHVNC

/// RDP input encodings: X11 keysyms (what the viewers already produce, `X11Keysym`) to set-1 scancodes for the
/// special keys, everything else typed as Unicode; pointer flags of MS-RDPBCGR 2.2.8.1.1.3.1.1.3.
public enum RDPInput {
    public struct Scancode: Equatable, Sendable {
        public var code: UInt16
        public var extended: Bool
    }

    public enum Button: Sendable { case left, right, middle }

    public static let move: UInt16 = 0x0800
    public static let down: UInt16 = 0x8000
    public static let wheel: UInt16 = 0x0200
    public static let wheelNegative: UInt16 = 0x0100

    public static func flags(_ button: Button, down isDown: Bool) -> UInt16 {
        let b: UInt16 = switch button { case .left: 0x1000; case .right: 0x2000; case .middle: 0x4000 }
        return b | (isDown ? down : 0)
    }

    /// One wheel notch (120): up is positive, down negative (9-bit two's complement in the low bits).
    public static func wheelFlags(up: Bool) -> UInt16 {
        up ? wheel | 0x0078 : wheel | wheelNegative | 0x0088
    }

    /// The scancode of a special key; nil for keys that are typed as characters.
    public static func scancode(forKeysym sym: UInt32) -> Scancode? {
        switch sym {
        case X11Keysym.returnKey: Scancode(code: 0x1C, extended: false)
        case X11Keysym.escape: Scancode(code: 0x01, extended: false)
        case X11Keysym.backspace: Scancode(code: 0x0E, extended: false)
        case X11Keysym.tab: Scancode(code: 0x0F, extended: false)
        case X11Keysym.left: Scancode(code: 0x4B, extended: true)
        case X11Keysym.up: Scancode(code: 0x48, extended: true)
        case X11Keysym.right: Scancode(code: 0x4D, extended: true)
        case X11Keysym.down: Scancode(code: 0x50, extended: true)
        case X11Keysym.home: Scancode(code: 0x47, extended: true)
        case X11Keysym.end: Scancode(code: 0x4F, extended: true)
        case X11Keysym.pageUp: Scancode(code: 0x49, extended: true)
        case X11Keysym.pageDown: Scancode(code: 0x51, extended: true)
        case X11Keysym.insert: Scancode(code: 0x52, extended: true)
        case X11Keysym.delete: Scancode(code: 0x53, extended: true)
        case X11Keysym.shiftLeft: Scancode(code: 0x2A, extended: false)
        case X11Keysym.controlLeft: Scancode(code: 0x1D, extended: false)
        case X11Keysym.altLeft: Scancode(code: 0x38, extended: false)
        case X11Keysym.metaLeft, X11Keysym.superLeft: Scancode(code: 0x5B, extended: true)   // the Windows key
        case 0xffbe...0xffc7: Scancode(code: 0x3B + UInt16(sym - 0xffbe), extended: false)  // F1–F10
        case 0xffc8: Scancode(code: 0x57, extended: false)                                  // F11
        case 0xffc9: Scancode(code: 0x58, extended: false)                                  // F12
        default: nil
        }
    }
}
