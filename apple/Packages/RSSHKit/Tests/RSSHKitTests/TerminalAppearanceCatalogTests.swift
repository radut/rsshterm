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

    /// Saved settings and servers keep these ids: a build must never drop or rename one.
    @Test func shippedIdsStayResolvable() {
        let shipped = ["default-dark", "default-light", "catppuccin-mocha", "catppuccin-latte", "dracula", "github-dark",
                       "github-light", "gruvbox-dark", "gruvbox-light", "monokai", "nord", "one-dark", "solarized-dark",
                       "solarized-light", "tokyo-night", "tomorrow-night",
                       // added with the themes-fonts work
                       "darcula", "intellij-light", "ayu-dark", "ayu-mirage", "ayu-light", "everforest-dark",
                       "everforest-light", "rose-pine", "rose-pine-moon", "rose-pine-dawn", "kanagawa-wave",
                       "kanagawa-dragon", "kanagawa-lotus", "nightfox", "carbonfox", "dawnfox", "material-darker",
                       "material-ocean", "material-light", "night-owl", "night-owl-light", "synthwave-84",
                       "catppuccin-frappe", "catppuccin-macchiato", "tokyo-night-storm", "tokyo-night-moon",
                       "tokyo-night-day", "github-dark-dimmed", "solarized-osaka", "solarized-osaka-light",
                       "gruvbox-material-dark", "gruvbox-material-light", "one-light", "one-half-dark", "one-half-light",
                       "tomorrow", "ghostty-default", "horizon", "snazzy", "palenight", "tango-dark", "tango-light",
                       "campbell", "vscode-dark-modern", "vscode-light-modern", "vscode-dark-plus", "xcode-dark",
                       "xcode-light"]
        for id in shipped {
            #expect(TerminalColorSchemes.scheme(id: id)?.id == id, "lost \(id)")
        }
        #expect(TerminalColorSchemes.all.count == shipped.count, "new theme: add its id to this list")
        #expect(TerminalColorSchemes.defaultDark.background == "#000000")
        #expect(TerminalPreferences().darkThemeID == TerminalColorSchemes.defaultDark.id)
    }

    @Test func popularComesFirstMostUsedFirstThenAllAtoZ() {
        let popular = TerminalColorSchemes.popular.map(\.id)
        #expect(Array(popular.prefix(5)) == ["default-dark", "default-light", "dracula", "one-dark", "github-dark"])
        #expect(popular.count == TerminalColorSchemes.popularIDs.count + 2, "every popular id resolves")
        #expect(Set(popular).count == popular.count)
        #expect(popular.contains("darcula"))
        let names = TerminalColorSchemes.alphabetical.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(names.count == TerminalColorSchemes.all.count)
    }

    @Test func searchMatchesEveryWordIgnoringCaseAndAccents() {
        #expect(TerminalColorSchemes.matching("").count == TerminalColorSchemes.all.count)
        #expect(TerminalColorSchemes.matching("rose pine").map(\.id) == ["rose-pine", "rose-pine-dawn", "rose-pine-moon"])
        #expect(TerminalColorSchemes.matching("FRAPPE").map(\.id) == ["catppuccin-frappe"])
        #expect(TerminalColorSchemes.matching("tokyo day").map(\.id) == ["tokyo-night-day"])
        #expect(TerminalColorSchemes.matching("zzz").isEmpty)
        let popularDark = TerminalColorSchemes.matching("dark", in: TerminalColorSchemes.popular)
        #expect(popularDark.first?.id == "default-dark")
    }

    @Test func darkFlagFollowsTheBackground() {
        for s in TerminalColorSchemes.all {
            let rgb = TerminalColorScheme.rgb(s.background) ?? 0
            let luma = 0.2126 * Double(rgb >> 16 & 0xFF) + 0.7152 * Double(rgb >> 8 & 0xFF) + 0.0722 * Double(rgb & 0xFF)
            #expect(s.isDark == (luma < 127.5), "\(s.name)")
            #expect(s.foreground != s.background && s.selection != s.foreground, "\(s.name)")
        }
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
        #expect(bundled.count == 25)
        for f in bundled {
            #expect(f.regular != nil && f.bold != nil, "\(f.name)")
            #expect(f.license?.isEmpty == false, "\(f.name)")
        }
    }

    @Test func requestedFamiliesAreThere() {
        let names = Set(TerminalFontCatalog.families.map(\.name))
        for n in ["JetBrains Mono", "Fira Code", "Cascadia Code", "Source Code Pro", "IBM Plex Mono",
                  "Hack", "Ubuntu Mono", "Inconsolata", "DejaVu Sans Mono", "Meslo LG M", "Roboto Mono",
                  "Victor Mono", "Iosevka Term", "Menlo", "Courier New", "Courier", "Maple Mono", "Monaspace Neon",
                  "Geist Mono", "Commit Mono", "Fira Mono", "0xProto", "Go Mono", "Intel One Mono", "Martian Mono",
                  "Space Mono", "Anonymous Pro", "Red Hat Mono", "Monaco"] {
            #expect(names.contains(n), "missing \(n)")
        }
    }

    @Test func monacoIsTheMacsOwn() {
        #expect(TerminalFontCatalog.families(for: .macOS).contains { $0.name == "Monaco" })
        #expect(!TerminalFontCatalog.families(for: .iOS).contains { $0.name == "Monaco" })
        #expect(TerminalFontCatalog.families(for: .iOS).count == TerminalFontCatalog.families.count - 1)
    }

    @Test func popularFontsComeFirstThenAllAtoZ() {
        let sections = TerminalFontCatalog.gallery(families: TerminalFontCatalog.families(for: .iOS))
        #expect(sections.map(\.title) == ["Popular", "All"])
        let popular = sections[0].items.map(\.name)
        #expect(Array(popular.prefix(4)) == ["System", "JetBrains Mono", "Meslo LG M", "Fira Code"])
        #expect(!popular.contains("Monaco"), "iOS has no Monaco")
        let all = sections[1].items.map(\.name)
        #expect(all == all.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(all.count == TerminalFontCatalog.families(for: .iOS).count)
        for name in TerminalFontCatalog.popularNames {
            #expect(TerminalFontCatalog.families.contains { $0.name == name }, "\(name)")
        }
        let found = TerminalFontCatalog.gallery(query: "mono fira", families: TerminalFontCatalog.families)
        #expect(found.map(\.title) == ["All"])
        #expect(found[0].items.map(\.name) == ["Fira Mono"])
    }

    @Test func themeGalleryFiltersAndSearches() {
        let dark = TerminalColorSchemes.gallery(filter: .dark)
        #expect(dark.map(\.title) == ["Popular", "All"])
        #expect(dark.allSatisfy { $0.items.allSatisfy(\.isDark) })
        #expect(dark[0].items.first?.id == "default-dark")
        let light = TerminalColorSchemes.gallery(filter: .light)
        #expect(light[0].items.first?.id == "default-light")
        #expect(light.allSatisfy { $0.items.allSatisfy { !$0.isDark } })
        let all = TerminalColorSchemes.gallery()
        #expect(all[1].items.count == TerminalColorSchemes.all.count)
        let search = TerminalColorSchemes.gallery(query: "darcula", filter: .all)
        #expect(search.map(\.title) == ["All"])
        #expect(search[0].items.map(\.id) == ["darcula"])
        #expect(TerminalColorSchemes.gallery(query: "darcula", filter: .light).isEmpty)
    }

    @Test func droppedCascadiaMonoBecomesCascadiaCode() throws {
        #expect(!TerminalFontCatalog.families.contains { $0.name == "Cascadia Mono" })
        #expect(TerminalFontCatalog.family(named: "Cascadia Mono").name == "Cascadia Code")
        let saved = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"fontFamily":"Cascadia Mono"}"#.utf8))
        #expect(saved.fontFamily == "Cascadia Code")
        var server = Server(name: "a", host: "h", username: "u")
        server.fontFamily = "Cascadia Mono"
        #expect(TerminalPreferences().forServer(server).fontFamily == "Cascadia Code")
        #expect(TerminalFontCatalog.migratedName("Hack") == "Hack")
    }

    @Test func unknownFamilyFallsBackToSystem() {
        #expect(TerminalFontCatalog.family(named: "Comic Sans") == TerminalFontCatalog.system)
        #expect(TerminalFontCatalog.family(named: "Hack").name == "Hack")
    }

    @Test func groupsCoverEveryFamilyOnce() {
        let grouped = TerminalFontFamily.Group.allCases.flatMap { TerminalFontCatalog.families(in: $0) }
        #expect(grouped.count == TerminalFontCatalog.families.count)
        #expect(TerminalFontCatalog.families(in: .ligatures).allSatisfy { $0.hasLigatures })
    }
}
