import Foundation
import Testing
@testable import RSSHKit

/// The app's look and the terminal's colours are two settings: a black terminal in a white app, and the reverse.
@Suite struct AppAppearanceTests {
    @Test func defaultsToFollowingThePhone() {
        #expect(TerminalPreferences().appAppearance == .system)
    }

    /// Settings saved before the split: their `theme` keeps choosing the terminal's colours, the app follows the phone.
    @Test func oldSettingsKeepTheirTerminalThemeAndTheAppFollowsThePhone() throws {
        let json = #"{"theme":"dark","lightThemeID":"solarized-light","darkThemeID":"nord","fontSize":14}"#
        let p = try JSONDecoder().decode(TerminalPreferences.self, from: Data(json.utf8))
        #expect(p.theme == .dark)
        #expect(p.appAppearance == .system)
        #expect(p.darkThemeID == "nord")
        #expect(p.fontSize == 14)
    }

    @Test func unknownAppAppearanceFallsBackToSystem() throws {
        let p = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"appAppearance":"sepia"}"#.utf8))
        #expect(p.appAppearance == .system)
    }

    @Test func roundTripsThroughJSON() throws {
        let p = TerminalPreferences(theme: .dark, appAppearance: .light)
        let back = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(p))
        #expect(back.appAppearance == .light)
        #expect(back.theme == .dark)
    }

    /// The terminal's colours never depend on the app's look: server theme, then the terminal setting, then the phone.
    @Test(arguments: TerminalPreferences.Appearance.allCases)
    func terminalThemeIgnoresTheAppAppearance(_ app: TerminalPreferences.Appearance) {
        let dark = TerminalPreferences(theme: .dark, appAppearance: app, darkThemeID: "nord")
        #expect(TerminalColorSchemeResolver.scheme(preferences: dark, serverThemeID: nil, systemIsDark: false).id == "nord")
        let light = TerminalPreferences(theme: .light, appAppearance: app, lightThemeID: "solarized-light")
        #expect(TerminalColorSchemeResolver.scheme(preferences: light, serverThemeID: nil, systemIsDark: true).id
                == "solarized-light")
        let phone = TerminalPreferences(theme: .system, appAppearance: app, lightThemeID: "solarized-light",
                                        darkThemeID: "nord")
        #expect(TerminalColorSchemeResolver.scheme(preferences: phone, serverThemeID: nil, systemIsDark: true).id == "nord")
        #expect(TerminalColorSchemeResolver.scheme(preferences: phone, serverThemeID: nil, systemIsDark: false).id
                == "solarized-light")
        #expect(TerminalColorSchemeResolver.scheme(preferences: dark, serverThemeID: "dracula", systemIsDark: false).id
                == "dracula")
    }
}
