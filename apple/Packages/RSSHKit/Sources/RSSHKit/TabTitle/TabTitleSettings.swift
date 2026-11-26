import Foundation

/// What a tab shows: line 1 (bold: the name) and line 2 (smaller, secondary colour: the live details).
public struct TabTitleLabel: Equatable, Sendable {
    public var title: String
    public var subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    /// Both lines in one, for compact tab bars: "deploy — root@sv1 · vim x". A subtitle that starts with the
    /// title stands alone ("root@sv1 · vim x", not "root@sv1 — root@sv1 · vim x").
    public var singleLine: String {
        if subtitle.isEmpty { return title }
        if title.isEmpty || subtitle.hasPrefix(title) { return subtitle }
        return title + " — " + subtitle
    }

    /// The window's title: both lines joined.
    public var windowTitle: String { singleLine }
}

/// Settings › Terminal › Tab Titles: two templates and the one-line option. Stored as JSON (UserDefaults on iOS and
/// macOS, the settings file on Linux); missing keys decode as the defaults.
public struct TabTitleSettings: Hashable, Sendable, Codable {
    /// Line 1: the user's name for the tab, else the vault server, else user@host.
    public static let defaultTitle = "{custom|server|user@host|host|title}"
    /// Line 2: where and what: "root@sv1 · vim /etc/nginx/nginx.conf", or "root@sv1 · ~/projects" when idle.
    public static let defaultSubtitle = "{user@host|host}{process? · {process} {args}}{!process? · {cwdShort}}"
    /// Shown when every fact is missing.
    public static let fallbackTitle = "Terminal"
    /// Longest line a tab shows (end ellipsis); placeholders have their own caps.
    public static let maxLength = 100

    public var title: String
    public var subtitle: String
    /// One line in the tab bar: `TabTitleLabel.singleLine`.
    public var singleLine: Bool

    public init(title: String = TabTitleSettings.defaultTitle, subtitle: String = TabTitleSettings.defaultSubtitle,
                singleLine: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.singleLine = singleLine
    }

    private enum CodingKeys: String, CodingKey { case title, subtitle, singleLine }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? Self.defaultTitle
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? Self.defaultSubtitle
        singleLine = (try? c.decodeIfPresent(Bool.self, forKey: .singleLine)) ?? false
    }

    /// The parse error of each template, nil when it is fine (the settings page shows it under the field).
    public var problems: (title: TabTitleTemplateError?, subtitle: TabTitleTemplateError?) {
        (Self.problem(title), Self.problem(subtitle))
    }

    private static func problem(_ source: String) -> TabTitleTemplateError? {
        do {
            _ = try TabTitleTemplate(source)
            return nil
        } catch {
            return error
        }
    }

    /// Both lines for `facts`. A template that does not parse renders as its default.
    public func label(for facts: TabTitleFacts) -> TabTitleLabel {
        let title = TabTitleTemplate.render(self.title, facts, fallback: Self.defaultTitle)
        let subtitle = TabTitleTemplate.render(self.subtitle, facts, fallback: Self.defaultSubtitle)
        return TabTitleLabel(
            title: TitleText.endEllipsis(title.isEmpty ? Self.fallbackTitle : title, max: Self.maxLength),
            subtitle: TitleText.endEllipsis(subtitle, max: Self.maxLength))
    }
}
