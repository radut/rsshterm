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
    /// Where the face exists: bundled families everywhere Apple, Monaco only on the Mac.
    public let platforms: Set<FontPlatform>

    public var id: String { name }
    public var hasLigatures: Bool { group == .ligatures }

    public init(_ name: String, _ group: Group, regular: String?, bold: String?, italic: String? = nil,
                boldItalic: String? = nil, isBundled: Bool = true, license: String? = nil,
                platforms: Set<FontPlatform> = [.iOS, .macOS]) {
        self.name = name
        self.group = group
        self.regular = regular
        self.bold = bold
        self.italic = italic
        self.boldItalic = boldItalic
        self.isBundled = isBundled
        self.license = license
        self.platforms = platforms
    }
}

public enum FontPlatform: String, Sendable, Hashable { case iOS, macOS }

/// The terminal fonts: the platform's own monospaced faces plus the bundled open-licence families (Resources/Fonts).
public enum TerminalFontCatalog {
    /// PostScript name of the Nerd Font symbols face every terminal font falls back to (powerline, devicons, …).
    public static let symbolsFallback = "SymbolsNFM"
    public static let symbolsLicense = "Symbols Nerd Font Mono 3.5.1: MIT; glyph sets under their own licences"

    private static let ofl = "SIL Open Font License 1.1"

    public static let families: [TerminalFontFamily] = [
        TerminalFontFamily(TerminalPreferences.systemFontFamily, .builtIn, regular: nil, bold: nil, isBundled: false),
        TerminalFontFamily("Monaco", .builtIn, regular: "Monaco", bold: nil, isBundled: false, platforms: [.macOS]),
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
        TerminalFontFamily("0xProto", .ligatures, regular: "0xProto-Regular", bold: "0xProto-Bold",
                           license: "0xProto 2.502: \(ofl)"),
        TerminalFontFamily("Iosevka Term", .ligatures, regular: "Iosevka-Term", bold: "Iosevka-Term-Bold",
                           license: "Iosevka 34.9.1 (subset): \(ofl)"),
        TerminalFontFamily("JetBrains Mono", .ligatures, regular: "JetBrainsMono-Regular", bold: "JetBrainsMono-Bold",
                           italic: "JetBrainsMono-Italic", boldItalic: "JetBrainsMono-BoldItalic",
                           license: "JetBrains Mono 2.304: \(ofl)"),
        TerminalFontFamily("Maple Mono", .ligatures, regular: "MapleMono-Regular", bold: "MapleMono-Bold",
                           italic: "MapleMono-Italic", license: "Maple Mono 7.9: \(ofl)"),
        TerminalFontFamily("Martian Mono", .ligatures, regular: "MartianMono-StdRg", bold: "MartianMono-StdBd",
                           license: "Martian Mono 1.1.0: \(ofl)"),
        TerminalFontFamily("Monaspace Neon", .ligatures, regular: "MonaspaceNeon-Regular", bold: "MonaspaceNeon-Bold",
                           license: "Monaspace 1.400: \(ofl)"),
        TerminalFontFamily("Victor Mono", .ligatures, regular: "VictorMono-Regular", bold: "VictorMono-Bold",
                           italic: "VictorMono-Italic", boldItalic: "VictorMono-BoldItalic",
                           license: "Victor Mono 1.5.6: \(ofl)"),

        TerminalFontFamily("Cascadia Mono", .classic, regular: "CascadiaMono-Regular", bold: "CascadiaMono-Bold",
                           license: "Cascadia Mono 2407.24: \(ofl)"),
        TerminalFontFamily("Anonymous Pro", .classic, regular: "AnonymousPro-Regular", bold: "AnonymousPro-Bold",
                           license: "Anonymous Pro 1.003: \(ofl)"),
        TerminalFontFamily("Commit Mono", .classic, regular: "CommitMono-Regular", bold: "CommitMono-Bold",
                           license: "Commit Mono 1.143: \(ofl)"),
        TerminalFontFamily("DejaVu Sans Mono", .classic, regular: "DejaVuSansMono", bold: "DejaVuSansMono-Bold",
                           italic: "DejaVuSansMono-Oblique", boldItalic: "DejaVuSansMono-BoldOblique",
                           license: "DejaVu Sans Mono 2.37: Bitstream Vera licence, DejaVu changes public domain"),
        TerminalFontFamily("Fira Mono", .classic, regular: "FiraMono-Regular", bold: "FiraMono-Bold",
                           license: "Fira Mono 3.206: \(ofl)"),
        TerminalFontFamily("Geist Mono", .classic, regular: "GeistMono-Regular", bold: "GeistMono-Bold",
                           license: "Geist Mono 1.9.2: \(ofl)"),
        TerminalFontFamily("Go Mono", .classic, regular: "GoMono", bold: "GoMono-Bold",
                           license: "Go Mono 2.010: BSD 3-Clause (the Go fonts licence)"),
        TerminalFontFamily("Hack", .classic, regular: "Hack-Regular", bold: "Hack-Bold", italic: "Hack-Italic",
                           boldItalic: "Hack-BoldItalic",
                           license: "Hack 3.003: MIT and Bitstream Vera licence"),
        TerminalFontFamily("IBM Plex Mono", .classic, regular: "IBMPlexMono", bold: "IBMPlexMono-Bold",
                           italic: "IBMPlexMono-Italic", boldItalic: "IBMPlexMono-BoldItalic",
                           license: "IBM Plex Mono 2.5.0: \(ofl)"),
        TerminalFontFamily("Intel One Mono", .classic, regular: "IntelOneMono-Regular", bold: "IntelOneMono-Bold",
                           license: "Intel One Mono 1.5.0: \(ofl)"),
        TerminalFontFamily("Inconsolata", .classic, regular: "Inconsolata-Regular", bold: "Inconsolata-Bold",
                           license: "Inconsolata 3.000: \(ofl)"),
        TerminalFontFamily("Meslo LG M", .classic, regular: "MesloLGM-Regular", bold: "MesloLGM-Bold",
                           license: "Meslo LG 1.2.1: Apache License 2.0 (from Bitstream Vera)"),
        TerminalFontFamily("Red Hat Mono", .classic, regular: "RedHatMono-Regular", bold: "RedHatMono-Bold",
                           license: "Red Hat Mono 1.030: \(ofl)"),
        TerminalFontFamily("Roboto Mono", .classic, regular: "RobotoMono-Regular", bold: "RobotoMono-Bold",
                           italic: "RobotoMono-Italic", boldItalic: "RobotoMono-BoldItalic",
                           license: "Roboto Mono 3.001: \(ofl)"),
        TerminalFontFamily("Space Mono", .classic, regular: "SpaceMono-Regular", bold: "SpaceMono-Bold",
                           license: "Space Mono 1.003: \(ofl)"),
        TerminalFontFamily("Source Code Pro", .classic, regular: "SourceCodePro-Regular", bold: "SourceCodePro-Bold",
                           italic: "SourceCodePro-It", boldItalic: "SourceCodePro-BoldIt",
                           license: "Source Code Pro 2.042: \(ofl)"),
        TerminalFontFamily("Ubuntu Mono", .classic, regular: "UbuntuMono-Regular", bold: "UbuntuMono-Bold",
                           italic: "UbuntuMono-Italic", boldItalic: "UbuntuMono-BoldItalic",
                           license: "Ubuntu Mono 0.83: Ubuntu Font Licence 1.0"),
    ]

    public static var system: TerminalFontFamily { families[0] }

    /// The font picker's "Popular" section, most used first (docs/research/themes-fonts.md: Homebrew installs,
    /// GitHub stars, Google Fonts). System is SF Mono; a name the platform lacks (Monaco on iOS) is skipped.
    public static let popularNames = [
        TerminalPreferences.systemFontFamily, "JetBrains Mono", "Meslo LG M", "Fira Code", "Hack", "Menlo", "Maple Mono",
        "Iosevka Term", "Source Code Pro", "Cascadia Code", "0xProto", "Go Mono", "IBM Plex Mono", "Monaco",
    ]

    /// The families a platform can draw (Monaco is the Mac's own).
    public static func families(for platform: FontPlatform) -> [TerminalFontFamily] {
        families.filter { $0.platforms.contains(platform) }
    }

    /// The family saved under `name`; System when it is unknown (renamed or removed in a later build).
    public static func family(named name: String) -> TerminalFontFamily {
        families.first { $0.name == name } ?? system
    }

    public static func families(in group: TerminalFontFamily.Group) -> [TerminalFontFamily] {
        families.filter { $0.group == group }
    }
}
