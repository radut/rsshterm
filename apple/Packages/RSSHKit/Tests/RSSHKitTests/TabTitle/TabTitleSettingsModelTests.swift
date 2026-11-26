import Foundation
import Testing
@testable import RSSHKit

@Suite struct TabTitleSettingsModelTests {
    @Test func presetsResetAndProblems() {
        var model = TabTitleSettingsModel()
        model.apply(TabTitleCatalog.subtitlePresets[0], to: .subtitle)
        #expect(model.settings.subtitle == "{host}")
        #expect(model.selectedPreset(for: .subtitle)?.name == "Minimal")
        model.set("{host", for: .subtitle)
        #expect(model.problem(for: .subtitle) != nil)
        #expect(model.selectedPreset(for: .subtitle) == nil)
        model.resetToDefaults()
        #expect(model.settings == TabTitleSettings())
        #expect(model.problem(for: .title) == nil)
    }

    @Test func previewsRenderEverySample() {
        var model = TabTitleSettingsModel()
        #expect(model.previews.count == TabTitleCatalog.samples.count)
        #expect(model.previews.contains { $0.label.title == "deploy" })
        model.settings.singleLine = true
        #expect(model.previews.allSatisfy { !$0.line.contains("\n") })
    }

    @Test func insertingAtTheCursor() {
        var model = TabTitleSettingsModel()
        model.set("{user}@", for: .title)
        let cursor = model.insert(TabTitleCatalog.placeholders.first { $0.name == "host" }!, into: .title, at: 7)
        #expect(model.settings.title == "{user}@{host}")
        #expect(cursor == 13)
    }

    @Test func storedInTerminalPreferences() throws {
        var prefs = TerminalPreferences()
        #expect(prefs.tabTitles == TabTitleSettings())
        prefs.tabTitles.singleLine = true
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(TerminalPreferences.self, from: data).tabTitles.singleLine)
        let old = try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8))
        #expect(old.tabTitles == TabTitleSettings())
    }
}
