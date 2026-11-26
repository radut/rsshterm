import RSSHDesktopCore
import Testing
@testable import RSSHTermLinux

@Suite struct KeyTranslatorTests {
    typealias M = GdkModifiers

    private func chord(_ keyval: UInt32, _ mods: M) -> String? {
        KeyTranslator.chord(keyval: keyval, modifiers: mods)?.description
    }

    @Test func lettersAreLowercaseWithShiftKept() {
        #expect(chord(0x54, [.control, .shift]) == "ctrl+shift+t") // GDK_KEY_T
        #expect(chord(0x74, [.control]) == "ctrl+t")
        #expect(chord(0x6b, [.control, .shift]) == "ctrl+shift+k")
    }

    @Test func digitsForTabSwitching() {
        #expect(chord(0x31, [.control]) == "ctrl+1")
        #expect(chord(0x39, [.alt]) == "alt+9")
    }

    @Test func shiftedSymbolsMapBackToTheirKey() {
        // Ctrl+Shift+] arrives as braceright on a US layout, Ctrl+Shift+Alt+= as plus.
        #expect(chord(0x7d, [.control, .shift]) == "ctrl+shift+]")
        #expect(chord(0x7b, [.control, .shift]) == "ctrl+shift+[")
        #expect(chord(0x2b, [.control, .shift, .alt]) == "ctrl+alt+shift+=")
    }

    @Test func namedKeys() {
        #expect(chord(0xff51, [.alt]) == "alt+left")
        #expect(chord(0xff53, [.alt]) == "alt+right")
        #expect(chord(0xff52, [.alt]) == "alt+up")
        #expect(chord(0xff54, [.alt]) == "alt+down")
        #expect(chord(0xff56, [.control]) == "ctrl+pagedown")
        #expect(chord(0xff55, [.control, .shift]) == "ctrl+shift+pageup")
        #expect(chord(0xff09, [.control]) == "ctrl+tab")
        #expect(chord(0xfe20, [.control, .shift]) == "ctrl+shift+tab") // ISO_Left_Tab
        #expect(chord(0xff0d, [.shift]) == "shift+enter")
        #expect(chord(0xff8d, []) == "enter") // keypad Enter
        #expect(chord(0xffbe, []) == "f1")
        #expect(chord(0xffc9, []) == "f12")
        #expect(chord(0xff1b, []) == "escape")
    }

    @Test func superIsCommandAndLockKeysAreIgnored() {
        #expect(chord(0x74, [.superKey]) == "cmd+t")
        // Caps Lock (lock mask) and Num Lock (mod2) never change the chord.
        #expect(KeyTranslator.chord(keyval: 0x54, rawState: 0x4 | 0x1 | 0x2 | 0x10)?.description == "ctrl+shift+t")
    }

    @Test func modifierOnlyAndUnknownKeysAreNil() {
        #expect(chord(0xffe3, [.control]) == nil) // Control_L
        #expect(chord(0xffe1, [.shift]) == nil) // Shift_L
        #expect(chord(0x1008ff11, []) == nil) // XF86AudioLowerVolume
    }

    @Test func linuxDefaultsResolve() {
        let keys = Keybindings.defaults(for: .linux)
        func action(_ keyval: UInt32, _ mods: M) -> DesktopAction? {
            KeyTranslator.chord(keyval: keyval, modifiers: mods).flatMap(keys.action(for:))
        }
        #expect(action(0x54, [.control, .shift]) == .newTab)
        #expect(action(0x45, [.control, .shift]) == .splitRight)
        #expect(action(0x4f, [.control, .shift]) == .splitDown)
        #expect(action(0x57, [.control, .shift]) == .closePane)
        #expect(action(0x4b, [.control, .shift]) == .hostSearch)
        #expect(action(0x33, [.control]) == .selectTab(3))
        #expect(action(0xff51, [.alt]) == .focus(.left))
        #expect(action(0x7d, [.control, .shift]) == .nextPane)
        #expect(action(0x74, [.control]) == nil) // plain Ctrl+T stays the shell's
    }

    @Test func clipboardChords() {
        #expect(KeyTranslator.clipboard(keyval: 0x43, modifiers: [.control, .shift]) == .copy)
        #expect(KeyTranslator.clipboard(keyval: 0x56, modifiers: [.control, .shift]) == .paste)
        #expect(KeyTranslator.clipboard(keyval: 0x63, modifiers: [.control]) == nil) // Ctrl+C is SIGINT
    }
}
