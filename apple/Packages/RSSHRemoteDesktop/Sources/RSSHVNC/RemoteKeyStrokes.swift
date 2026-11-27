import RSSHKit

/// The terminal's key row (`KeyAction`, with its sticky modifiers) as key presses on a remote screen: X11 keysyms
/// down and up, modifiers pressed around the key. Shared by the VNC and RDP viewers (RDPInput turns the same keysyms
/// into scancodes).
public enum RemoteKeyStrokes {
    public struct Stroke: Equatable, Sendable {
        public let keysym: UInt32
        public let down: Bool
        public init(_ keysym: UInt32, down: Bool) {
            self.keysym = keysym
            self.down = down
        }
    }

    /// The presses for `action` and the latch afterwards. `meta`: the ⌘ (Mac) / Windows key, held with the key.
    /// Latching a modifier sends nothing; paste and paging are the app's (nothing here).
    public static func strokes(for action: KeyAction, latch: ModifierLatch,
                               meta: Bool = false) -> (strokes: [Stroke], latch: ModifierLatch) {
        switch action {
        case .key(let key):
            guard let sym = keysym(for: key) else { return ([], latch.consumed()) }
            return (wrapped([sym], modifiers: latch.active, meta: meta), latch.consumed())
        case .text(let text):
            return (wrapped(X11Keysym.keysyms(typing: text), modifiers: latch.active, meta: meta), latch.consumed())
        case .combo(let key, let mods):
            guard let sym = keysym(for: key) else { return ([], latch.consumed()) }
            return (wrapped([sym], modifiers: mods.union(latch.active), meta: meta), latch.consumed())
        case .wordEdit(let edit):
            let strokes = desktopKeys(for: edit).flatMap { key, mods in
                keysym(for: key).map { wrapped([$0], modifiers: mods, meta: meta) } ?? []
            }
            return (strokes, latch.consumed())
        case .latch(let modifier):
            return ([], latch.tapped(modifier))
        case .paste, .morePages:
            return ([], latch)
        }
    }

    public static func keysym(for key: TerminalKey) -> UInt32? {
        switch key {
        case .character(let c): c.unicodeScalars.count == 1 ? c.unicodeScalars.first.flatMap(X11Keysym.keysym(for:)) : nil
        case .escape: X11Keysym.escape
        case .tab: X11Keysym.tab
        case .enter: X11Keysym.returnKey
        case .backspace: X11Keysym.backspace
        case .delete: X11Keysym.delete
        case .insert: X11Keysym.insert
        case .up: X11Keysym.up
        case .down: X11Keysym.down
        case .left: X11Keysym.left
        case .right: X11Keysym.right
        case .home: X11Keysym.home
        case .end: X11Keysym.end
        case .pageUp: X11Keysym.pageUp
        case .pageDown: X11Keysym.pageDown
        case .function(let n): X11Keysym.function(n)
        }
    }

    /// Word and line editing as desktop editors take it (Ctrl+arrows, Home/End; deleting to the line's start or
    /// end selects with Shift, then deletes), not the shell's bytes.
    static func desktopKeys(for edit: WordEdit) -> [(TerminalKey, KeyModifiers)] {
        switch edit {
        case .wordLeft: [(.left, .ctrl)]
        case .wordRight: [(.right, .ctrl)]
        case .deleteWordBack: [(.backspace, .ctrl)]
        case .deleteWordForward: [(.delete, .ctrl)]
        case .lineStart: [(.home, [])]
        case .lineEnd: [(.end, [])]
        case .deleteToLineStart: [(.home, .shift), (.backspace, [])]
        case .deleteToLineEnd: [(.end, .shift), (.delete, [])]
        }
    }

    private static func wrapped(_ keys: [UInt32], modifiers: KeyModifiers, meta: Bool) -> [Stroke] {
        guard !keys.isEmpty else { return [] }
        var held: [UInt32] = []
        if modifiers.contains(.ctrl) { held.append(X11Keysym.controlLeft) }
        if modifiers.contains(.alt) { held.append(X11Keysym.altLeft) }
        if modifiers.contains(.shift) { held.append(X11Keysym.shiftLeft) }
        if meta { held.append(X11Keysym.metaLeft) }
        return held.map { Stroke($0, down: true) }
            + keys.flatMap { [Stroke($0, down: true), Stroke($0, down: false)] }
            + held.reversed().map { Stroke($0, down: false) }
    }
}
