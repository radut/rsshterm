import Foundation
import Testing
@testable import RSSHKit

@Suite struct TerminalColorSchemeTests {
    @Test func everyThemeHas16ValidColours() {
        for s in TerminalColorSchemes.all {
            #expect(s.ansi.count == 16, "\(s.name)")
            for hex in s.ansi + [s.background, s.foreground, s.cursor, s.selection] {
                #expect(TerminalColorScheme.rgb(hex) != nil, "\(s.name): \(hex)")
            }
            #expect(!s.source.isEmpty)
        }
    }

    @Test func idsAndNamesAreUnique() {
        #expect(Set(TerminalColorSchemes.all.map(\.id)).count == TerminalColorSchemes.all.count)
        #expect(Set(TerminalColorSchemes.all.map(\.name)).count == TerminalColorSchemes.all.count)
    }

    @Test func galleryHasTheRequestedThemes() {
        let names = Set(TerminalColorSchemes.all.map(\.name))
        for n in ["Solarized Dark", "Solarized Light", "Dracula", "Nord", "Gruvbox Dark", "Gruvbox Light", "One Dark",
                  "Monokai", "Tomorrow Night", "Catppuccin Latte", "Catppuccin Mocha", "Tokyo Night", "GitHub Light",
                  "GitHub Dark", "Default Dark", "Default Light"] {
            #expect(names.contains(n), "missing \(n)")
        }
        #expect(TerminalColorSchemes.dark.allSatisfy { $0.isDark })
        #expect(!TerminalColorSchemes.light.contains { $0.isDark })
    }

    @Test func hexParsing() {
        #expect(TerminalColorScheme.rgb("#1A2b3C") == 0x1A2B3C)
        #expect(TerminalColorScheme.rgb("1A2B3C") == nil)
        #expect(TerminalColorScheme.rgb("#1A2B3") == nil)
        #expect(TerminalColorScheme.rgb("#GGGGGG") == nil)
    }

    @Test func defaultsAreDarkThenFollowTheChosenAppearance() {
        var p = TerminalPreferences()
        p.lightThemeID = "solarized-light"
        p.darkThemeID = "nord"
        // A new install is black even on a light phone.
        #expect(TerminalColorSchemeResolver.scheme(preferences: p, serverThemeID: nil, systemIsDark: false).id == "nord")
        p.theme = .system
        #expect(TerminalColorSchemeResolver.scheme(preferences: p, serverThemeID: nil, systemIsDark: true).id == "nord")
        #expect(TerminalColorSchemeResolver.scheme(preferences: p, serverThemeID: nil, systemIsDark: false).id
            == "solarized-light")
        p.theme = .dark
        #expect(TerminalColorSchemeResolver.scheme(preferences: p, serverThemeID: nil, systemIsDark: false).id == "nord")
        p.theme = .light
        #expect(TerminalColorSchemeResolver.scheme(preferences: p, serverThemeID: nil, systemIsDark: true).id
            == "solarized-light")
    }

    @Test func serverOverrideWinsAndUnknownIdsFallBack() {
        var p = TerminalPreferences()
        #expect(TerminalColorSchemeResolver.scheme(preferences: p, serverThemeID: "dracula", systemIsDark: false).id
            == "dracula")
        #expect(TerminalColorSchemeResolver.scheme(preferences: p, serverThemeID: "gone", systemIsDark: true).id
            == TerminalColorSchemes.defaultDark.id)
        p.darkThemeID = "removed-in-a-later-build"
        #expect(TerminalColorSchemeResolver.scheme(preferences: p, serverThemeID: nil, systemIsDark: true)
            == TerminalColorSchemes.defaultDark)
    }

    @Test func themeChoiceRoundTripsAndOldSettingsLoad() throws {
        let p = TerminalPreferences(theme: .dark, lightThemeID: "github-light", darkThemeID: "tokyo-night")
        let back = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        let old = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"theme":"light"}"#.utf8))
        #expect(old.theme == .light)
        #expect(old.lightThemeID == TerminalColorSchemes.defaultLight.id)
        #expect(old.darkThemeID == TerminalColorSchemes.defaultDark.id)
    }

    @Test func serverThemeRoundTripsThroughTheDraft() throws {
        let server = Server(name: "a", host: "h", username: "u", themeID: "monokai")
        let made = try ServerDraft(server: server).makeServer(id: server.id)
        #expect(made.themeID == "monokai")
        let decoded = try JSONDecoder().decode(Server.self, from: Data(
            #"{"id":"\#(UUID().uuidString)","name":"a","host":"h","port":22,"username":"u"}"#.utf8))
        #expect(decoded.themeID == nil)
    }
}

@Suite struct TerminalFontCatalogTests {
    @Test func namesAreUniqueAndSystemComesFirst() {
        let names = TerminalFontCatalog.families.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(TerminalFontCatalog.system.name == TerminalPreferences.systemFontFamily)
        #expect(TerminalFontCatalog.system.regular == nil)
    }

    @Test func bundledFamiliesHaveARegularABoldAndALicence() {
        let bundled = TerminalFontCatalog.families.filter(\.isBundled)
        #expect(bundled.count == 14)
        for f in bundled {
            #expect(f.regular != nil && f.bold != nil, "\(f.name)")
            #expect(f.license?.isEmpty == false, "\(f.name)")
        }
    }

    @Test func requestedFamiliesAreThere() {
        let names = Set(TerminalFontCatalog.families.map(\.name))
        for n in ["JetBrains Mono", "Fira Code", "Cascadia Code", "Cascadia Mono", "Source Code Pro", "IBM Plex Mono",
                  "Hack", "Ubuntu Mono", "Inconsolata", "DejaVu Sans Mono", "Meslo LG M", "Roboto Mono",
                  "Victor Mono", "Iosevka Term", "Menlo", "Courier New", "Courier"] {
            #expect(names.contains(n), "missing \(n)")
        }
    }

    @Test func unknownFamilyFallsBackToSystem() {
        #expect(TerminalFontCatalog.family(named: "Monaco") == TerminalFontCatalog.system)
        #expect(TerminalFontCatalog.family(named: "Hack").name == "Hack")
    }

    @Test func groupsCoverEveryFamilyOnce() {
        let grouped = TerminalFontFamily.Group.allCases.flatMap { TerminalFontCatalog.families(in: $0) }
        #expect(grouped.count == TerminalFontCatalog.families.count)
        #expect(TerminalFontCatalog.families(in: .ligatures).allSatisfy { $0.hasLigatures })
    }
}
