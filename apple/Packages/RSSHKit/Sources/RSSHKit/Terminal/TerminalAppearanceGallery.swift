import Foundation

/// What the theme and font pickers show on every platform: a "Popular" section (most used first, see
/// docs/research/themes-fonts.md), then "All" A–Z, both narrowed by the search field.
public struct GallerySection<Item: Identifiable>: Identifiable {
    public enum Kind: String, Sendable { case popular = "Popular", all = "All" }

    public let kind: Kind
    public let items: [Item]
    public var id: String { kind.rawValue }
    public var title: String { kind.rawValue }
}

public enum ThemeFilter: String, CaseIterable, Sendable, Identifiable {
    case dark = "Dark", light = "Light", all = "All"
    public var id: String { rawValue }

    func admits(_ scheme: TerminalColorScheme) -> Bool {
        switch self {
        case .dark: scheme.isDark
        case .light: !scheme.isDark
        case .all: true
        }
    }
}

public extension TerminalColorSchemes {
    /// Popular then All, each kept to `filter` and to the names matching `query`. With a query the Popular section
    /// is left out (each match shows once, A–Z); empty sections are dropped.
    static func gallery(query: String = "", filter: ThemeFilter = .all) -> [GallerySection<TerminalColorScheme>] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        var sections: [GallerySection<TerminalColorScheme>] = []
        if !searching {
            sections.append(GallerySection(kind: .popular, items: popular.filter(filter.admits)))
        }
        sections.append(GallerySection(kind: .all, items: matching(query, in: alphabetical).filter(filter.admits)))
        return sections.filter { !$0.items.isEmpty }
    }
}

public extension TerminalFontCatalog {
    /// The font picker: Popular then All A–Z, narrowed by `query`. `families` is what the platform can draw
    /// (TerminalFontCatalog.families(for:)).
    static func gallery(query: String = "", families: [TerminalFontFamily]) -> [GallerySection<TerminalFontFamily>] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches: (TerminalFontFamily) -> Bool = { family in
            words.allSatisfy { family.name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        let available = Dictionary(families.map { ($0.name, $0) }) { first, _ in first }
        let az = families.filter(matches).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var sections: [GallerySection<TerminalFontFamily>] = []
        if words.isEmpty {
            sections.append(GallerySection(kind: .popular, items: popularNames.compactMap { available[$0] }))
        }
        sections.append(GallerySection(kind: .all, items: az))
        return sections.filter { !$0.items.isEmpty }
    }
}
