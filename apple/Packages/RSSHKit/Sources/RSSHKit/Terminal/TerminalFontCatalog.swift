import Foundation

/// One family in Settings › Terminal › Font. `name` is what is saved in `TerminalPreferences.fontFamily`.
public struct TerminalFontFamily: Hashable, Sendable, Identifiable {
    public enum Group: String, CaseIterable, Sendable {
        case builtIn = "Built In"
        case ligatures = "With Ligatures"
        case classic = "Without Ligatures"
    }

    public let name: String
    public let group: Group
    /// PostScript names of the faces; nil for "System", which is the platform's monospaced font.
    public let regular: String?
    public let bold: String?
    public let italic: String?
    public let boldItalic: String?
    /// Bundled with the app (a file under Resources/Fonts) rather than shipped by iOS.
    public let isBundled: Bool
    /// Licence shown in Acknowledgements; nil for fonts iOS ships.
    public let license: String?

    public var id: String { name }
    public var hasLigatures: Bool { group == .ligatures }

    public init(_ name: String, _ group: Group, regular: String?, bold: String?, italic: String? = nil,
                boldItalic: String? = nil, isBundled: Bool = true, license: String? = nil) {
        self.name = name
        self.group = group
        self.regular = regular
        self.bold = bold
        self.italic = italic
        self.boldItalic = boldItalic
        self.isBundled = isBundled
        self.license = license
    }
}

/// The terminal fonts: iOS's own monospaced faces plus the bundled open-licence families (Resources/Fonts).
public enum TerminalFontCatalog {
    /// PostScript name of the Nerd Font symbols face every terminal font falls back to (powerline, devicons, …).
    public static let symbolsFallback = "SymbolsNFM"
    public static let symbolsLicense = "Symbols Nerd Font Mono 3.5.1: MIT; glyph sets under their own licences"

    private static let ofl = "SIL Open Font License 1.1"

    public static let families: [TerminalFontFamily] = [
        TerminalFontFamily(TerminalPreferences.systemFontFamily, .builtIn, regular: nil, bold: nil, isBundled: false),
        TerminalFontFamily("Menlo", .builtIn, regular: "Menlo-Regular", bold: "Menlo-Bold", italic: "Menlo-Italic",
                           boldItalic: "Menlo-BoldItalic", isBundled: false),
        TerminalFontFamily("Courier New", .builtIn, regular: "CourierNewPSMT", bold: "CourierNewPS-BoldMT",
                           italic: "CourierNewPS-ItalicMT", boldItalic: "CourierNewPS-BoldItalicMT", isBundled: false),
        TerminalFontFamily("Courier", .builtIn, regular: "Courier", bold: "Courier-Bold", italic: "Courier-Oblique",
                           boldItalic: "Courier-BoldOblique", isBundled: false),

        TerminalFontFamily("Cascadia Code", .ligatures, regular: "CascadiaCode-Regular", bold: "CascadiaCode-Bold",
                           license: "Cascadia Code 2407.24: \(ofl)"),
        TerminalFontFamily("Fira Code", .ligatures, regular: "FiraCode-Regular", bold: "FiraCode-Bold",
                           license: "Fira Code 6.2: \(ofl)"),
        TerminalFontFamily("Iosevka Term", .ligatures, regular: "Iosevka-Term", bold: "Iosevka-Term-Bold",
                           license: "Iosevka 34.9.1 (subset): \(ofl)"),
        TerminalFontFamily("JetBrains Mono", .ligatures, regular: "JetBrainsMono-Regular", bold: "JetBrainsMono-Bold",
                           italic: "JetBrainsMono-Italic", boldItalic: "JetBrainsMono-BoldItalic",
                           license: "JetBrains Mono 2.304: \(ofl)"),
        TerminalFontFamily("Victor Mono", .ligatures, regular: "VictorMono-Regular", bold: "VictorMono-Bold",
                           italic: "VictorMono-Italic", boldItalic: "VictorMono-BoldItalic",
                           license: "Victor Mono 1.5.6: \(ofl)"),

        TerminalFontFamily("Cascadia Mono", .classic, regular: "CascadiaMono-Regular", bold: "CascadiaMono-Bold",
                           license: "Cascadia Mono 2407.24: \(ofl)"),
        TerminalFontFamily("DejaVu Sans Mono", .classic, regular: "DejaVuSansMono", bold: "DejaVuSansMono-Bold",
                           italic: "DejaVuSansMono-Oblique", boldItalic: "DejaVuSansMono-BoldOblique",
                           license: "DejaVu Sans Mono 2.37: Bitstream Vera licence, DejaVu changes public domain"),
        TerminalFontFamily("Hack", .classic, regular: "Hack-Regular", bold: "Hack-Bold", italic: "Hack-Italic",
                           boldItalic: "Hack-BoldItalic",
                           license: "Hack 3.003: MIT and Bitstream Vera licence"),
        TerminalFontFamily("IBM Plex Mono", .classic, regular: "IBMPlexMono", bold: "IBMPlexMono-Bold",
                           italic: "IBMPlexMono-Italic", boldItalic: "IBMPlexMono-BoldItalic",
                           license: "IBM Plex Mono 2.5.0: \(ofl)"),
        TerminalFontFamily("Inconsolata", .classic, regular: "Inconsolata-Regular", bold: "Inconsolata-Bold",
                           license: "Inconsolata 3.000: \(ofl)"),
        TerminalFontFamily("Meslo LG M", .classic, regular: "MesloLGM-Regular", bold: "MesloLGM-Bold",
                           license: "Meslo LG 1.2.1: Apache License 2.0 (from Bitstream Vera)"),
        TerminalFontFamily("Roboto Mono", .classic, regular: "RobotoMono-Regular", bold: "RobotoMono-Bold",
                           italic: "RobotoMono-Italic", boldItalic: "RobotoMono-BoldItalic",
                           license: "Roboto Mono 3.001: \(ofl)"),
        TerminalFontFamily("Source Code Pro", .classic, regular: "SourceCodePro-Regular", bold: "SourceCodePro-Bold",
                           italic: "SourceCodePro-It", boldItalic: "SourceCodePro-BoldIt",
                           license: "Source Code Pro 2.042: \(ofl)"),
        TerminalFontFamily("Ubuntu Mono", .classic, regular: "UbuntuMono-Regular", bold: "UbuntuMono-Bold",
                           italic: "UbuntuMono-Italic", boldItalic: "UbuntuMono-BoldItalic",
                           license: "Ubuntu Mono 0.83: Ubuntu Font Licence 1.0"),
    ]

    public static var system: TerminalFontFamily { families[0] }

    /// The family saved under `name`; System when it is unknown (renamed or removed in a later build).
    public static func family(named name: String) -> TerminalFontFamily {
        families.first { $0.name == name } ?? system
    }

    public static func families(in group: TerminalFontFamily.Group) -> [TerminalFontFamily] {
        families.filter { $0.group == group }
    }
}
