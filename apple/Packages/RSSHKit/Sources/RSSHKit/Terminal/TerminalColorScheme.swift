import Foundation

/// One terminal colour theme: background, foreground, cursor, selection and the 16 ANSI colours, as "#RRGGBB".
/// Data only; the app turns it into UIKit and SwiftTerm colours.
public struct TerminalColorScheme: Hashable, Sendable, Identifiable {
    /// Stable key saved in preferences and on servers; never shown.
    public let id: String
    public let name: String
    public let isDark: Bool
    public let background: String
    public let foreground: String
    public let cursor: String
    public let selection: String
    /// 0-7 normal, then 8-15 bright.
    public let ansi: [String]
    /// Where the palette is published and under which licence (Settings › About › Acknowledgements).
    public let source: String

    public init(id: String, name: String, isDark: Bool, background: String, foreground: String, cursor: String,
                selection: String, ansi: [String], source: String) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
        self.source = source
    }

    /// "#RRGGBB" as 0xRRGGBB; nil when it is not exactly that form.
    public static func rgb(_ hex: String) -> UInt32? {
        guard hex.count == 7, hex.first == "#" else { return nil }
        let digits = hex.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }
}

/// Which theme a terminal shows: the server's own choice when it has one, otherwise the light or dark default.
public enum TerminalColorSchemeResolver {
    /// `serverThemeID` nil (or no longer known) means "use the default". `systemIsDark` is the phone's appearance.
    public static func scheme(preferences: TerminalPreferences, serverThemeID: String?,
                              systemIsDark: Bool) -> TerminalColorScheme {
        if let serverThemeID, let own = TerminalColorSchemes.scheme(id: serverThemeID) { return own }
        let dark: Bool = switch preferences.theme {
        case .system: systemIsDark
        case .dark: true
        case .light: false
        }
        let id = dark ? preferences.darkThemeID : preferences.lightThemeID
        return TerminalColorSchemes.scheme(id: id) ?? (dark ? TerminalColorSchemes.defaultDark : TerminalColorSchemes.defaultLight)
    }
}
