import Foundation
import Testing
@testable import RSSHKit

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
private let natural = WordEditingSettings()
private let linux = WordEditingSettings(preset: .linux)

private func map(_ key: TerminalKey, _ mods: HardwareModifiers = [], _ settings: WordEditingSettings = natural,
                 side: OptionSide = .unknown, app: Bool = false) -> [UInt8]? {
    HardwareKeyMap.bytes(for: key, modifiers: mods, optionSide: side, settings: settings, applicationCursor: app)
}

@Suite struct HardwareKeyMapNaturalTests {
    @Test func optionArrowsMoveByWord() {
        #expect(map(.left, .option) == bytes("\u{1B}b"))
        #expect(map(.right, .option) == bytes("\u{1B}f"))
    }

    @Test func commandArrowsGoToLineEnds() {
        #expect(map(.left, .command) == [0x01])
        #expect(map(.right, .command) == [0x05])
    }

    @Test func optionBackspaceDeletesWordBack() {
        #expect(map(.backspace, .option) == [0x1B, 0x7F])
    }

    @Test func commandBackspaceDeletesToLineStart() {
        #expect(map(.backspace, .command) == [0x15])
    }

    @Test func forwardDeleteRows() {
        #expect(map(.delete) == bytes("\u{1B}[3~"))
        #expect(map(.delete, .option) == bytes("\u{1B}d"))
        #expect(map(.delete, .command) == [0x0B])
    }

    @Test func ctrlKeysStayLinuxInTheNaturalPreset() {
        #expect(map(.left, .control) == bytes("\u{1B}[1;5D"))
        #expect(map(.right, .control) == bytes("\u{1B}[1;5C"))
        #expect(map(.backspace, .control) == [0x17])
        #expect(map(.delete, .control) == bytes("\u{1B}[3;5~"))
    }
}

@Suite struct HardwareKeyMapLinuxTests {
    @Test func ctrlArrows() {
        #expect(map(.left, .control, linux) == bytes("\u{1B}[1;5D"))
        #expect(map(.right, .control, linux) == bytes("\u{1B}[1;5C"))
    }

    @Test func ctrlBackspaceIsCtrlWByDefaultOrCtrlH() {
        #expect(map(.backspace, .control, linux) == [0x17])
        var ctrlH = linux
        ctrlH.ctrlBackspace = .ctrlH
        #expect(map(.backspace, .control, ctrlH) == [0x08])
    }

    @Test func ctrlDeleteIsXtermOrEscD() {
        #expect(map(.delete, .control, linux) == bytes("\u{1B}[3;5~"))
        var escD = linux
        escD.ctrlDelete = .escD
        #expect(map(.delete, .control, escD) == bytes("\u{1B}d"))
    }

    @Test func altBackspaceAndAltArrows() {
        #expect(map(.backspace, .option, linux) == [0x1B, 0x7F])
        #expect(map(.left, .option, linux) == bytes("\u{1B}[1;3D"))
        #expect(map(.right, .option, linux) == bytes("\u{1B}[1;3C"))
        #expect(map(.delete, .option, linux) == bytes("\u{1B}[3;3~"))
    }

    @Test func homeEndNormal() {
        #expect(map(.home, [], linux) == bytes("\u{1B}[H"))
        #expect(map(.end, [], linux) == bytes("\u{1B}[F"))
    }

    @Test func commandKeysAreLeftToTheView() {
        #expect(map(.left, .command, linux) == nil)
        #expect(map(.right, .command, linux) == nil)
        #expect(map(.backspace, .command, linux) == nil)
        #expect(map(.delete, .command, linux) == nil)
    }
}

@Suite struct HardwareKeyMapCommonTests {
    @Test func plainArrowsFollowApplicationCursor() {
        #expect(map(.left) == bytes("\u{1B}[D"))
        #expect(map(.left, app: true) == bytes("\u{1B}OD"))
        #expect(map(.up, app: true) == bytes("\u{1B}OA"))
        #expect(map(.home, app: true) == bytes("\u{1B}OH"))
    }

    @Test func modifiedArrowsIgnoreApplicationCursor() {
        #expect(map(.left, .control, app: true) == bytes("\u{1B}[1;5D"))
        #expect(map(.left, .option, app: true) == bytes("\u{1B}b"))
        #expect(map(.up, .option, app: true) == bytes("\u{1B}[1;3A"))
        #expect(map(.left, .shift, app: true) == bytes("\u{1B}[1;2D"))
    }

    @Test func plainBackspaceIsDel() {
        #expect(map(.backspace) == [0x7F])
    }

    @Test func unmappedKeysFallThrough() {
        #expect(map(.pageUp) == nil)
        #expect(map(.character("c"), .control) == nil)
        #expect(map(.character("v"), .command) == nil)
        #expect(map(.character("a")) == nil)
        #expect(map(.left, [.command, .option]) == nil)
        #expect(map(.up, .command) == nil)
    }

    @Test func optionLetterIsMetaWhenThatSideIsMeta() {
        #expect(map(.character("b"), .option) == bytes("\u{1B}b"))
        let left = WordEditingSettings(optionAsMeta: .left)
        #expect(map(.character("b"), .option, left, side: .left) == bytes("\u{1B}b"))
        #expect(map(.character("b"), .option, left, side: .right) == nil)
        let right = WordEditingSettings(optionAsMeta: .right)
        #expect(map(.character("b"), .option, right, side: .left) == nil)
        #expect(map(.character("b"), .option, right, side: .right) == bytes("\u{1B}b"))
        let off = WordEditingSettings(optionAsMeta: .off)
        #expect(map(.character("b"), .option, off) == nil)
        #expect(map(.character("B"), [.option, .shift]) == bytes("\u{1B}B"))
        #expect(map(.character("b"), [.option, .control]) == nil)
    }
}

@Suite struct WordEditTests {
    @Test func onScreenWordEditsFollowThePreset() {
        #expect(WordEdit.wordLeft.bytes(natural) == bytes("\u{1B}b"))
        #expect(WordEdit.wordRight.bytes(natural) == bytes("\u{1B}f"))
        #expect(WordEdit.deleteWordBack.bytes(natural) == [0x1B, 0x7F])
        #expect(WordEdit.wordLeft.bytes(linux) == bytes("\u{1B}[1;5D"))
        #expect(WordEdit.wordRight.bytes(linux) == bytes("\u{1B}[1;5C"))
        #expect(WordEdit.deleteWordBack.bytes(linux) == [0x17])
    }

    @Test func longPressActionResolvesAndConsumesTheLatch() {
        let latch = ModifierLatch().tapped(.ctrl)
        let (sent, after) = KeyAction.wordEdit(.wordLeft).resolve(latch: latch, applicationCursor: false,
                                                                  wordEditing: natural)
        #expect(sent == bytes("\u{1B}b"))
        #expect(after.active.isEmpty)
    }

    @Test func arrowsAndBackspaceChipHaveLongPress() {
        #expect(ExtraKeyLayout.mainRow.first { $0.accessibilityName == "Left" }?.longPress == .wordEdit(.wordLeft))
        #expect(ExtraKeyLayout.mainRow.first { $0.accessibilityName == "Right" }?.longPress == .wordEdit(.wordRight))
        #expect(ExtraKeyLayout.optionalChips.first { $0.id == "backspace" }?.key.longPress == .wordEdit(.deleteWordBack))
    }

    @Test func optionalChipsDefaultToBackspaceOnly() {
        let base = ExtraKeyLayout.chips.count
        #expect(ExtraKeyLayout.chips(enabled: ExtraKeyLayout.defaultOptionalChipIDs).count == base + 1)
        let all = ExtraKeyLayout.chips(enabled: ["ctrlE", "ctrlW", "ctrlU", "ctrlA", "backspace", "ctrlL", "ctrlC",
                                                 "ctrlD"]).map(\.label)
        #expect(Array(all.suffix(8)) == ["⌫", "Ctrl+C", "Ctrl+D", "Ctrl+L", "Ctrl+W", "Ctrl+U", "Ctrl+A", "Ctrl+E"])
    }
}

@Suite struct WordEditingSettingsTests {
    @Test func defaultsAreNaturalCtrlWXtermBoth() {
        let d = WordEditingSettings()
        #expect(d.preset == .natural && d.ctrlBackspace == .ctrlW && d.ctrlDelete == .xterm && d.optionAsMeta == .both)
    }

    @Test func oldPreferencesLoadWithDefaults() throws {
        let json = bytes(#"{"fontSize":14}"#)
        let prefs = try JSONDecoder().decode(TerminalPreferences.self, from: Data(json))
        #expect(prefs.wordEditing == WordEditingSettings())
        #expect(prefs.optionalChipIDs == ["backspace"])
    }

    @Test func roundTrip() throws {
        var prefs = TerminalPreferences()
        prefs.wordEditing = WordEditingSettings(preset: .linux, ctrlBackspace: .ctrlH, ctrlDelete: .escD,
                                                optionAsMeta: .left)
        prefs.optionalChipIDs = ["ctrlW"]
        let back = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back == prefs)
    }

    @Test func unknownValueFallsBackToDefault() throws {
        let json = bytes(#"{"preset":"vi","ctrlBackspace":"ctrlH"}"#)
        let s = try JSONDecoder().decode(WordEditingSettings.self, from: Data(json))
        #expect(s.preset == .natural && s.ctrlBackspace == .ctrlH)
    }
}

@Suite struct WordEditingShortcutsTests {
    @Test func naturalListShowsOptionAndCommandRows() {
        let list = WordEditingShortcuts.list(natural)
        #expect(list.first { $0.keys == "⌥←" }?.sends == "ESC b")
        #expect(list.first { $0.keys == "⌘⌫" }?.sends == "^U")
        #expect(list.first { $0.keys == "⌃⌫" }?.sends == "^W")
        #expect(list.first { $0.keys == "⌃→" }?.sends == "ESC [1;5C")
        #expect(list.first { $0.keys == "⌥⌫" }?.sends == "ESC DEL")
    }

    @Test func linuxListDropsCommandRows() {
        let list = WordEditingShortcuts.list(linux)
        #expect(!list.contains { $0.keys.hasPrefix("⌘") })
        #expect(list.first { $0.keys == "⌥←" }?.sends == "ESC [1;3D")
    }
}
