import Testing
@testable import RSSHKit

@Suite struct ModifierLatchTests {
    @Test func tapLatchesForOneKeyThenReleases() {
        let latched = ModifierLatch().tapped(.ctrl)
        #expect(latched.active == .ctrl)
        #expect(latched.state(of: .ctrl) == .once)
        let after = latched.consumed()
        #expect(after.active.isEmpty)
    }

    @Test func secondTapLocksThirdReleases() {
        let locked = ModifierLatch().tapped(.alt).tapped(.alt)
        #expect(locked.state(of: .alt) == .locked)
        #expect(locked.consumed().active == .alt)
        #expect(locked.tapped(.alt).state(of: .alt) == .off)
    }

    @Test func modifiersCombine() {
        let both = ModifierLatch().tapped(.ctrl).tapped(.shift)
        #expect(both.active == [.ctrl, .shift])
        #expect(both.consumed() == ModifierLatch())
    }

    @Test func consumingNothingKeepsLocks() {
        let mixed = ModifierLatch().tapped(.ctrl).tapped(.alt).tapped(.alt)
        #expect(mixed.consumed().active == .alt)
    }

    @Test func clearedReleasesEverything() {
        #expect(ModifierLatch().tapped(.ctrl).tapped(.ctrl).cleared().active.isEmpty)
    }
}

@Suite struct ExtraKeyLayoutTests {
    @Test func keyRowInOrder() {
        let labels = ExtraKeyLayout.mainRow.map(\.label)
        #expect(labels == ["tab", "esc", "ctrl", "←", "↑", "↓", "→", "⏎", "…"])
    }

    @Test func mainRowHasTheBasics() {
        let row = ExtraKeyLayout.mainRow.map(\.action)
        #expect(row.contains(.key(.escape)))
        #expect(row.contains(.latch(.ctrl)))
        #expect(row.contains(.key(.tab)))
        for arrow in [TerminalKey.up, .down, .left, .right] { #expect(row.contains(.key(arrow))) }
        #expect(row.contains(.morePages))
    }

    @Test func pagesCoverSymbolsNavigationAndMeta() {
        let all = ExtraKeyLayout.pages.flatMap(\.keys).map(\.action)
        for s in ["/", "-", "|", "@", "~", ".", ":", ";"] { #expect(all.contains(.text(s)), "missing \(s)") }
        for k in [TerminalKey.pageUp, .pageDown, .home, .end, .delete] { #expect(all.contains(.key(k))) }
        // F keys live on the Fn row, not behind "…".
        #expect(!all.contains { if case .key(.function) = $0 { true } else { false } })
        #expect(all.contains(.latch(.alt)))
    }

    @Test func moreKeysCyclesSymbolsAndNavigationOnly() {
        #expect(ExtraKeyLayout.pages.map(\.title) == ["Symbols", "Navigation"])
    }

    @Test func functionRowIsF1ToF12() {
        #expect(ExtraKeyLayout.functionRow.map(\.label) == (1...12).map { "F\($0)" })
        #expect(ExtraKeyLayout.functionRow.map(\.action) == (1...12).map { .key(.function($0)) })
    }

    @Test func chipsInOrder() {
        #expect(ExtraKeyLayout.chips.map(\.label) == ["Paste", "#", "$", "`", "~", "|", "Ctrl+C", "Ctrl+D", "Ctrl+L"])
        #expect(ExtraKeyLayout.chips[6].action == .combo(.character("c"), .ctrl))
        #expect(ExtraKeyLayout.chips[0].action == .paste)
    }

    @Test func everyKeyHasALabelAndAnAccessibilityName() {
        let keys = ExtraKeyLayout.mainRow + ExtraKeyLayout.pages.flatMap(\.keys) + ExtraKeyLayout.chips
        for k in keys {
            #expect(!k.label.isEmpty)
            #expect(!k.accessibilityName.isEmpty)
        }
        #expect(Set(ExtraKeyLayout.pages.map(\.title)).count == ExtraKeyLayout.pages.count)
    }
}

@Suite struct KeyActionResolutionTests {
    @Test func keyActionAppliesLatchAndConsumesIt() {
        let latch = ModifierLatch().tapped(.ctrl)
        let (bytes, next) = KeyAction.key(.character("c")).resolve(latch: latch, applicationCursor: false)
        #expect(bytes == [0x03])
        #expect(next.active.isEmpty)
    }

    @Test func latchActionTogglesWithoutSending() {
        let (bytes, next) = KeyAction.latch(.alt).resolve(latch: ModifierLatch(), applicationCursor: false)
        #expect(bytes.isEmpty)
        #expect(next.active == .alt)
    }

    @Test func textActionHonoursLatch() {
        let (bytes, _) = KeyAction.text("~").resolve(latch: ModifierLatch().tapped(.alt), applicationCursor: false)
        #expect(bytes == [0x1B] + Array("~".utf8))
    }

    @Test func comboMergesWithLatch() {
        let (bytes, next) = KeyAction.combo(.up, .shift).resolve(latch: ModifierLatch().tapped(.ctrl),
                                                                  applicationCursor: true)
        #expect(bytes == Array("\u{1B}[1;6A".utf8))
        #expect(next.active.isEmpty)
    }

    @Test func pasteAndPagesSendNothingThemselves() {
        let latch = ModifierLatch().tapped(.ctrl)
        #expect(KeyAction.paste.resolve(latch: latch, applicationCursor: false).bytes.isEmpty)
        #expect(KeyAction.morePages.resolve(latch: latch, applicationCursor: false).latch == latch)
    }
}
