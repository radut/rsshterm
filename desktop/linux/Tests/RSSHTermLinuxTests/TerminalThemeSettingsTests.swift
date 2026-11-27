import Foundation
import RSSHKit
import Testing
@testable import RSSHTermLinux

@Suite struct TerminalThemeSettingsTests {
    @Test func defaultsAreTheBlackDefaultAndOnlyForcedLightIsLight() {
        var s = AppSettings()
        #expect(s.terminalScheme == TerminalColorSchemes.defaultDark)
        s.colorScheme = .dark
        #expect(s.terminalScheme.background == "#000000")
        s.colorScheme = .light
        #expect(s.terminalScheme == TerminalColorSchemes.defaultLight)
        s.lightThemeID = "solarized-light"
        #expect(s.terminalScheme.id == "solarized-light")
        s.colorScheme = .system
        s.darkThemeID = "darcula"
        #expect(s.terminalScheme.id == "darcula")
    }

    @Test func unknownThemeFallsBackAndOldFilesLoad() throws {
        var s = AppSettings()
        s.darkThemeID = "removed-later"
        #expect(s.terminalScheme == TerminalColorSchemes.defaultDark)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontName":"Hack 12"}"#.utf8))
        #expect(old.darkThemeID == "default-dark" && old.lightThemeID == "default-light")
        s.darkThemeID = "rose-pine"
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.darkThemeID == "rose-pine")
    }

    @Test func swatchAndPreviewDrawTheThemesOwnColours() {
        let scheme = try! #require(TerminalColorSchemes.scheme(id: "dracula"))
        let swatch = ThemeSwatchMarkup.swatch(scheme)
        #expect(swatch.hasPrefix("<tt>") && swatch.hasSuffix("</tt>"))
        #expect(swatch.contains("background=\"#282A36\""))
        for hex in scheme.ansi.prefix(8) { #expect(swatch.contains(hex)) }
        let preview = ThemeSwatchMarkup.preview(scheme)
        for hex in scheme.ansi { #expect(preview.contains(hex)) }
        #expect(preview.contains("-&gt; != &gt;= =&gt;"), "markup is escaped")
        #expect(ThemeSwatchMarkup.escape("SynthWave '84 <&>") == "SynthWave '84 &lt;&amp;&gt;")
    }
}
