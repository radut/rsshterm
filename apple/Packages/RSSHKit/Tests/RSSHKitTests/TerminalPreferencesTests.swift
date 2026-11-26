import Foundation
import Testing
@testable import RSSHKit

@Suite struct TerminalPreferencesTests {
    @Test func defaults() {
        let p = TerminalPreferences()
        #expect(p.theme == .dark)
        #expect(p.fontFamily == TerminalPreferences.systemFontFamily)
        #expect(p.fontSize == 13)
        #expect(p.keepDisplayOn)
        #expect(p.bell == .visual)
        #expect(p.showExtraKeyRow)
        #expect(p.showChipBar)
        #expect(!p.showFunctionKeyRow)
        #expect(p.showComposeTools)
        #expect(!p.reportCurrentFolder)
    }

    @Test func fontSizeIsClampedToTheAllowedRange() {
        #expect(TerminalPreferences(fontSize: 2).fontSize == 8)
        #expect(TerminalPreferences(fontSize: 99).fontSize == 24)
        #expect(TerminalPreferences().withFontSize(30).fontSize == 24)
        #expect(TerminalPreferences().withFontSize(10).fontSize == 10)
        #expect(TerminalPreferences.fontSizeRange == 8...24)
    }

    @Test func emptyFontFamilyFallsBackToTheSystemFont() {
        #expect(TerminalPreferences(fontFamily: "  ").fontFamily == TerminalPreferences.systemFontFamily)
    }

    @Test func roundTripsThroughJSON() throws {
        let p = TerminalPreferences(theme: .dark, fontFamily: "Menlo", fontSize: 18, keepDisplayOn: true, bell: .sound,
                                    showExtraKeyRow: false, showChipBar: false, showComposeTools: false,
                                    reportCurrentFolder: true)
        let back = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    @Test func missingAndUnknownValuesTakeTheDefaults() throws {
        let json = #"{"theme":"sepia","fontSize":200,"bell":"sound"}"#
        let p = try JSONDecoder().decode(TerminalPreferences.self, from: Data(json.utf8))
        #expect(p.theme == .dark)
        #expect(p.fontSize == 24)
        #expect(p.bell == .sound)
        #expect(p.showChipBar)
    }

    @Test func storeSavesAndLoads() throws {
        let defaults = try #require(UserDefaults(suiteName: "rssh-terminal-\(UUID().uuidString)"))
        let store = TerminalPreferencesStore(defaults: defaults)
        #expect(store.load() == TerminalPreferences())
        let p = TerminalPreferences(theme: .light, fontSize: 9)
        store.save(p)
        #expect(TerminalPreferencesStore(defaults: defaults).load() == p)
    }

    @Test func storeIgnoresUnreadableData() throws {
        let defaults = try #require(UserDefaults(suiteName: "rssh-terminal-\(UUID().uuidString)"))
        defaults.set(Data("nope".utf8), forKey: TerminalPreferencesStore.key)
        #expect(TerminalPreferencesStore(defaults: defaults).load() == TerminalPreferences())
    }

    @Test func functionKeyRowRoundTripsAndOldSettingsDefaultOff() throws {
        var p = TerminalPreferences()
        p.showFunctionKeyRow = true
        let back = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(p))
        #expect(back.showFunctionKeyRow)
        let old = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"showChipBar":false}"#.utf8))
        #expect(!old.showFunctionKeyRow)
        #expect(!old.showChipBar)
    }
}
