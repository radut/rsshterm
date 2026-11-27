import Foundation
import Testing
@testable import RSSHDesktopCore

@Suite struct KeybindingOverridesTests {
    private func c(_ text: String) -> KeyChord { try! KeyChord(parsing: text) }

    @Test func emptyOverridesAreTheDefaults() {
        for platform in [Platform.macOS, .linux] {
            #expect(KeybindingOverrides().keybindings(for: platform) == Keybindings.defaults(for: platform))
        }
    }

    @Test func encodesAsTheConfigFileSection() throws {
        let overrides = KeybindingOverrides(["newTab": ["cmd+alt+t"], "hostSearch": []])
        let json = try JSONEncoder().encode(overrides)
        let config = try JSONDecoder().decode(KeybindingConfig.self, from: json)
        #expect(config.keybindings == ["newTab": ["cmd+alt+t"], "hostSearch": []])
        #expect(try JSONDecoder().decode(KeybindingOverrides.self, from: json) == overrides)
        let text = #"{"keybindings": {"splitRight": ["cmd+e"]}}"#
        let decoded = try JSONDecoder().decode(KeybindingOverrides.self, from: Data(text.utf8))
        #expect(decoded.keybindings(for: .macOS).action(for: c("cmd+e")) == .splitRight)
    }

    @Test func badEntriesAreSkippedNotFatal() {
        // A file from a newer build (unknown action) or a hand edit (bad chord) still loads the rest.
        let overrides = KeybindingOverrides(["teleport": ["cmd+y"], "newTab": ["meta"], "splitRight": ["cmd+e"]])
        let keys = overrides.keybindings(for: .macOS)
        #expect(keys.action(for: c("cmd+e")) == .splitRight)
        #expect(keys.chords(for: .newTab) == [c("cmd+t")])
    }

    @Test func settingAShortcut() {
        let next = KeybindingOverrides().setting(.newTab, to: [c("cmd+alt+t")], platform: .macOS)
        let keys = next.keybindings(for: .macOS)
        #expect(keys.chords(for: .newTab) == [c("cmd+alt+t")])
        #expect(keys.action(for: c("cmd+t")) == nil)
        #expect(next.isCustomized(.newTab))
        #expect(!next.isCustomized(.splitRight))
    }

    @Test func conflictNamesTheOtherAction() {
        let none = KeybindingOverrides()
        #expect(none.conflict(for: c("cmd+d"), assigningTo: .newTab, platform: .macOS) == .splitRight)
        #expect(none.conflict(for: c("cmd+t"), assigningTo: .newTab, platform: .macOS) == nil) // its own
        #expect(none.conflict(for: c("cmd+alt+y"), assigningTo: .newTab, platform: .macOS) == nil)
    }

    @Test func reassigningTakesTheChordFromTheOtherAction() {
        let next = KeybindingOverrides().setting(.newTab, to: [c("cmd+d")], platform: .macOS)
        let keys = next.keybindings(for: .macOS)
        #expect(keys.action(for: c("cmd+d")) == .newTab)
        #expect(keys.chords(for: .splitRight).isEmpty)
        #expect(next.isCustomized(.splitRight)) // saved explicitly, not left to the order of the table
        // An action with two chords keeps the one not taken.
        let tab = KeybindingOverrides().setting(.newTab, to: [c("ctrl+tab")], platform: .macOS)
        #expect(tab.keybindings(for: .macOS).chords(for: .nextTab) == [c("cmd+shift+]")])
    }

    @Test func settingTheDefaultsBackDropsTheEntry() {
        let changed = KeybindingOverrides().setting(.newTab, to: [c("cmd+alt+t")], platform: .macOS)
        let back = changed.setting(.newTab, to: [c("cmd+t")], platform: .macOS)
        #expect(back == KeybindingOverrides())
    }

    @Test func resetOneAndAll() {
        var o = KeybindingOverrides()
        o = o.setting(.newTab, to: [c("cmd+alt+t")], platform: .macOS)
        o = o.setting(.hostSearch, to: [], platform: .macOS)
        let one = o.resetting(.newTab, platform: .macOS)
        #expect(one.keybindings(for: .macOS).chords(for: .newTab) == [c("cmd+t")])
        #expect(one.keybindings(for: .macOS).chords(for: .hostSearch).isEmpty)
        #expect(KeybindingOverrides.none.keybindings(for: .macOS) == Keybindings.defaults(for: .macOS))
    }

    @Test func resetTakesTheDefaultBackFromWhoeverHasIt() {
        // splitRight was given ⌘T; resetting newTab brings ⌘T home and leaves splitRight with nothing.
        let o = KeybindingOverrides().setting(.splitRight, to: [c("cmd+t")], platform: .macOS)
        #expect(o.keybindings(for: .macOS).chords(for: .newTab).isEmpty)
        let reset = o.resetting(.newTab, platform: .macOS)
        let keys = reset.keybindings(for: .macOS)
        #expect(keys.action(for: c("cmd+t")) == .newTab)
        #expect(keys.chords(for: .splitRight).isEmpty)
    }

    @Test func usableShortcutsNeedAModifier() {
        #expect(c("cmd+e").isUsableShortcut(on: .macOS))
        #expect(c("ctrl+tab").isUsableShortcut(on: .macOS))
        #expect(c("f5").isUsableShortcut(on: .macOS))
        #expect(!c("e").isUsableShortcut(on: .macOS))
        #expect(!c("shift+e").isUsableShortcut(on: .macOS))
        #expect(!c("alt+e").isUsableShortcut(on: .macOS)) // types ´ on a Mac
        #expect(c("alt+left").isUsableShortcut(on: .linux))
        #expect(!c("shift+e").isUsableShortcut(on: .linux))
    }

    @Test func macSymbolsAndLinuxText() {
        #expect(c("cmd+shift+d").displayText(on: .macOS) == "⇧⌘D")
        #expect(c("cmd+ctrl+alt+shift+i").displayText(on: .macOS) == "⌃⌥⇧⌘I")
        #expect(c("cmd+alt+left").displayText(on: .macOS) == "⌥⌘←")
        #expect(c("cmd+shift+enter").displayText(on: .macOS) == "⇧⌘↩")
        #expect(c("ctrl+tab").displayText(on: .macOS) == "⌃⇥")
        #expect(c("cmd+]").displayText(on: .macOS) == "⌘]")
        #expect(c("f5").displayText(on: .macOS) == "F5")
        #expect(c("ctrl+shift+t").displayText(on: .linux) == "Ctrl+Shift+T")
        #expect(c("ctrl+pagedown").displayText(on: .linux) == "Ctrl+Page Down")
    }

    @Test func everyActionHasATitleAndAGroup() {
        let titles = DesktopAction.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(DesktopAction.newTab.title == "New Tab")
        #expect(DesktopAction.focus(.left).title == "Focus Pane Left")
        #expect(DesktopAction.selectTab(9).title == "Select Last Tab")
        let grouped = DesktopAction.Category.allCases.flatMap { g in DesktopAction.allCases.filter { $0.category == g } }
        #expect(grouped.count == DesktopAction.allCases.count)
    }

    @Test func appActionsHaveMacDefaults() {
        let mac = Keybindings.defaults(for: .macOS)
        #expect(mac.chords(for: .biggerFont) == [c("cmd+=")])
        #expect(mac.chords(for: .smallerFont) == [c("cmd+-")])
        #expect(mac.chords(for: .resetFontSize) == [c("cmd+0")])
        #expect(mac.chords(for: .showServers) == [c("cmd+shift+s")])
        #expect(mac.chords(for: .quickConnect) == [c("cmd+shift+o")])
        #expect(mac.chords(for: .showFiles) == [c("cmd+shift+f")])
        #expect(mac.chords(for: .lockVault) == [c("cmd+ctrl+l")])
        #expect(DesktopAction(identifier: "biggerFont") == .biggerFont)
    }
}
