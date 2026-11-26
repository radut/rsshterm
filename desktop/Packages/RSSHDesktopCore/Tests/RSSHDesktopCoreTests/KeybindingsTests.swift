import Foundation
import Testing
@testable import RSSHDesktopCore

@Suite struct KeybindingsTests {
    @Test func chordParsingNormalizesOrderAndCase() throws {
        let chord = try KeyChord(parsing: "Shift+CMD+d")
        #expect(chord == KeyChord(key: "d", modifiers: [.command, .shift]))
        #expect(chord.description == "cmd+shift+d")
        #expect(try KeyChord(parsing: "ctrl+shift+PageDown").key == "pagedown")
        #expect(try KeyChord(parsing: "alt+left") == KeyChord(key: "left", modifiers: [.option]))
        #expect(try KeyChord(parsing: "ctrl++") == KeyChord(key: "+", modifiers: [.control]))
    }

    @Test(arguments: ["", "cmd+", "hyper+d", "cmd+shift", "ctrl+foo bar"])
    func badChordsAreRejected(_ text: String) {
        #expect(throws: KeybindingError.self) { try KeyChord(parsing: text) }
    }

    @Test func actionIdentifiersRoundTrip() {
        for action in DesktopAction.allCases {
            #expect(DesktopAction(identifier: action.identifier) == action)
        }
        #expect(DesktopAction(identifier: "selectTab3") == .selectTab(3))
        #expect(DesktopAction(identifier: "selectTab10") == nil)
        #expect(DesktopAction(identifier: "focusLeft") == .focus(.left))
        #expect(DesktopAction(identifier: "resizePaneDown") == .resizePane(.down))
    }

    @Test func macDefaultsUseCommand() {
        let keys = Keybindings.defaults(for: .macOS)
        #expect(keys.action(for: KeyChord(key: "t", modifiers: [.command])) == .newTab)
        #expect(keys.action(for: KeyChord(key: "d", modifiers: [.command])) == .splitRight)
        #expect(keys.action(for: KeyChord(key: "d", modifiers: [.command, .shift])) == .splitDown)
        #expect(keys.action(for: KeyChord(key: "k", modifiers: [.command])) == .hostSearch)
        for n in 1...9 {
            #expect(keys.action(for: KeyChord(key: "\(n)", modifiers: [.command])) == .selectTab(n))
        }
    }

    @Test func linuxDefaultsUseCtrlShiftAndCtrlNumbers() {
        let keys = Keybindings.defaults(for: .linux)
        #expect(keys.action(for: KeyChord(key: "t", modifiers: [.control, .shift])) == .newTab)
        #expect(keys.action(for: KeyChord(key: "w", modifiers: [.control, .shift])) == .closePane)
        #expect(keys.action(for: KeyChord(key: "3", modifiers: [.control])) == .selectTab(3))
        #expect(keys.action(for: KeyChord(key: "k", modifiers: [.control, .shift])) == .hostSearch)
        #expect(keys.chords(for: .nextTab).map(\.description) == ["ctrl+pagedown", "ctrl+tab"])
        // plain Ctrl+letter belongs to the shell (Ctrl+C, Ctrl+D, ...)
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            #expect(keys.action(for: KeyChord(key: String(letter), modifiers: [.control])) == nil)
        }
    }

    @Test(arguments: [Platform.macOS, Platform.linux])
    func everyActionHasADefault(_ platform: Platform) {
        let keys = Keybindings.defaults(for: platform)
        for action in DesktopAction.allCases where !Keybindings.menuOnly(platform).contains(action) {
            #expect(!keys.chords(for: action).isEmpty, "\(action)")
        }
    }

    @Test func renameTabAndJumpSwitcherDefaults() {
        let mac = Keybindings.defaults(for: .macOS)
        #expect(mac.action(for: KeyChord(key: "r", modifiers: [.command])) == .renameTab)
        #expect(mac.action(for: KeyChord(key: "j", modifiers: [.command])) == .jumpSwitcher)
        let linux = Keybindings.defaults(for: .linux)
        #expect(linux.action(for: KeyChord(key: "r", modifiers: [.control, .shift])) == .renameTab)
        #expect(linux.action(for: KeyChord(key: "j", modifiers: [.control, .shift])) == .jumpSwitcher)
        #expect(DesktopAction(identifier: "renameTab") == .renameTab)
        #expect(DesktopAction(identifier: "jumpSwitcher") == .jumpSwitcher)
    }

    @Test func overridesReplaceUnbindAndStealChords() throws {
        let keys = try Keybindings.defaults(for: .linux).applying([
            "newTab": ["ctrl+alt+n"],
            "hostSearch": [],
            "splitRight": ["ctrl+shift+t"], // was newTab's, which already moved
        ])
        #expect(keys.chords(for: .newTab) == [KeyChord(key: "n", modifiers: [.control, .option])])
        #expect(keys.chords(for: .hostSearch).isEmpty)
        #expect(keys.action(for: KeyChord(key: "t", modifiers: [.control, .shift])) == .splitRight)
        let stolen = try Keybindings.defaults(for: .linux).applying(["splitRight": ["ctrl+shift+t"]])
        #expect(stolen.chords(for: .newTab).isEmpty) // the chord moved to splitRight
    }

    @Test func overridesRejectUnknownActionsAndBadChords() {
        #expect(throws: KeybindingError.unknownAction("teleport")) {
            try Keybindings.defaults(for: .linux).applying(["teleport": ["ctrl+t"]])
        }
        #expect(throws: KeybindingError.self) { try Keybindings.defaults(for: .linux).applying(["newTab": ["meta"]]) }
    }

    @Test func configJSON() throws {
        let json = #"{"keybindings": {"commandPalette": ["ctrl+shift+space"]}}"#
        let config = try JSONDecoder().decode(KeybindingConfig.self, from: Data(json.utf8))
        let keys = try Keybindings.defaults(for: .linux).applying(config.keybindings)
        #expect(keys.action(for: try KeyChord(parsing: "ctrl+shift+space")) == .commandPalette)
    }
}
