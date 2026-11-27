import Foundation

/// How the terminal looks and behaves (Settings › Terminal and › Keyboard). Nothing secret: kept in UserDefaults.
public struct TerminalPreferences: Codable, Hashable, Sendable {
    /// The terminal's colours: `.system` follows the phone's light or dark appearance.
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case system, dark, light
    }

    /// The app's own look (lists, sheets, menus), apart from the terminal's colours: a black terminal in a white app
    /// is allowed. `.system` follows the phone.
    public enum Appearance: String, Codable, CaseIterable, Sendable {
        case system, light, dark
    }

    public enum Bell: String, Codable, CaseIterable, Sendable {
        case none, visual, sound
    }

    /// The platform's own monospaced font (SF Mono on iOS) rather than a named family.
    public static let systemFontFamily = "System"
    public static let fontSizeRange = 8...24
    public static let defaultFontSize = 13

    /// Which of the two terminal themes below shows: `.dark` (the default) always, `.system` follows the phone's light or
    /// dark appearance. Saved as
    /// `theme` since the first build, when it also set the app's look; that is `appAppearance` now.
    public var theme: Theme
    /// Light or dark for everything but the terminal. Missing in older saved settings: `.system`.
    public var appAppearance: Appearance
    /// `TerminalColorScheme.id` used in light mode and in dark mode.
    public var lightThemeID: String
    public var darkThemeID: String
    public var fontFamily: String
    /// Points, always inside `fontSizeRange`.
    public private(set) var fontSize: Int
    public var keepDisplayOn: Bool
    public var bell: Bell
    /// The esc / tab / ctrl / arrows row above the keyboard.
    public var showExtraKeyRow: Bool
    /// The scrollable Paste / Ctrl+C / … chips.
    public var showChipBar: Bool
    /// F1–F12 in one row above the extra key row (off: they stay behind "…").
    public var showFunctionKeyRow: Bool
    /// The compose, dictation and attach buttons in the terminal.
    public var showComposeTools: Bool
    /// Settings shows the OSC 7 shell hook and the terminal offers to install it.
    public var reportCurrentFolder: Bool
    /// The usernames Quick Connect offers (Settings › Quick Connect Users); trimmed, no blanks, no duplicates.
    public var quickConnectUsers: [String] { didSet { quickConnectUsers = Self.cleaned(quickConnectUsers) } }
    /// The username the last Quick Connect used; listed first next time.
    public var lastQuickConnectUser: String?
    /// Option/Cmd/Ctrl word and line editing on a hardware keyboard and the long-press keys on screen.
    public var wordEditing: WordEditingSettings
    /// Ids from `ExtraKeyLayout.optionalChips` shown after the fixed chips.
    public var optionalChipIDs: [String]
    /// Settings › Sessions: where sessions live on servers that do not choose for themselves.
    public var sessionBackend: SessionBackend
    /// Settings › Sessions: how long new kept sessions live on the server (each session can change its own).
    public var sessionTimeouts: SessionTimeouts
    /// Settings › Terminal › Tab Titles: the two title templates and the one-line option.
    public var tabTitles: TabTitleSettings

    public init(theme: Theme = .dark, appAppearance: Appearance = .system, lightThemeID: String = TerminalColorSchemes.defaultLight.id,
                darkThemeID: String = TerminalColorSchemes.defaultDark.id, fontFamily: String = TerminalPreferences.systemFontFamily,
                fontSize: Int = TerminalPreferences.defaultFontSize, keepDisplayOn: Bool = true, bell: Bell = .visual,
                showExtraKeyRow: Bool = true, showChipBar: Bool = true, showFunctionKeyRow: Bool = false,
                quickConnectUsers: [String] = TerminalPreferences.defaultQuickConnectUsers,
                lastQuickConnectUser: String? = nil, showComposeTools: Bool = true, reportCurrentFolder: Bool = false,
                wordEditing: WordEditingSettings = WordEditingSettings(),
                optionalChipIDs: [String] = ExtraKeyLayout.defaultOptionalChipIDs,
                sessionBackend: SessionBackend = .tmux, sessionTimeouts: SessionTimeouts = .standard,
                tabTitles: TabTitleSettings = TabTitleSettings()) {
        let family = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        self.theme = theme
        self.appAppearance = appAppearance
        self.lightThemeID = lightThemeID
        self.darkThemeID = darkThemeID
        self.fontFamily = family.isEmpty ? Self.systemFontFamily : family
        self.fontSize = Self.clamp(fontSize)
        self.keepDisplayOn = keepDisplayOn
        self.bell = bell
        self.showExtraKeyRow = showExtraKeyRow
        self.showChipBar = showChipBar
        self.showFunctionKeyRow = showFunctionKeyRow
        self.quickConnectUsers = Self.cleaned(quickConnectUsers)
        self.lastQuickConnectUser = lastQuickConnectUser
        self.showComposeTools = showComposeTools
        self.reportCurrentFolder = reportCurrentFolder
        self.wordEditing = wordEditing
        self.optionalChipIDs = optionalChipIDs
        self.sessionBackend = sessionBackend
        self.sessionTimeouts = sessionTimeouts
        self.tabTitles = tabTitles
    }

    /// The preferences a server's terminal uses: its own font family and size when it has them (server editor),
    /// these otherwise. Unknown families still go through `TerminalFontCatalog.family(named:)` at drawing time.
    public func forServer(_ server: Server?) -> TerminalPreferences {
        guard let server else { return self }
        var copy = self
        if let family = server.fontFamily, !family.isEmpty { copy.fontFamily = family }
        if let size = server.fontSize { copy = copy.withFontSize(size) }
        return copy
    }

    /// A copy with `size` clamped to `fontSizeRange`.
    public func withFontSize(_ size: Int) -> TerminalPreferences {
        var copy = self
        copy.fontSize = Self.clamp(size)
        return copy
    }

    private static func clamp(_ size: Int) -> Int {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// Missing or unknown values take their defaults, so settings from another build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TerminalPreferences()
        self.init(
            theme: (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? d.theme,
            appAppearance: (try? c.decodeIfPresent(Appearance.self, forKey: .appAppearance)) ?? d.appAppearance,
            lightThemeID: (try? c.decodeIfPresent(String.self, forKey: .lightThemeID)) ?? d.lightThemeID,
            darkThemeID: (try? c.decodeIfPresent(String.self, forKey: .darkThemeID)) ?? d.darkThemeID,
            fontFamily: (try? c.decodeIfPresent(String.self, forKey: .fontFamily)) ?? d.fontFamily,
            fontSize: (try? c.decodeIfPresent(Int.self, forKey: .fontSize)) ?? d.fontSize,
            keepDisplayOn: (try? c.decodeIfPresent(Bool.self, forKey: .keepDisplayOn)) ?? d.keepDisplayOn,
            bell: (try? c.decodeIfPresent(Bell.self, forKey: .bell)) ?? d.bell,
            showExtraKeyRow: (try? c.decodeIfPresent(Bool.self, forKey: .showExtraKeyRow)) ?? d.showExtraKeyRow,
            showChipBar: (try? c.decodeIfPresent(Bool.self, forKey: .showChipBar)) ?? d.showChipBar,
            showFunctionKeyRow: (try? c.decodeIfPresent(Bool.self, forKey: .showFunctionKeyRow)) ?? d.showFunctionKeyRow,
            quickConnectUsers: (try? c.decodeIfPresent([String].self, forKey: .quickConnectUsers)) ?? d.quickConnectUsers,
            lastQuickConnectUser: (try? c.decodeIfPresent(String.self, forKey: .lastQuickConnectUser)) ?? nil,
            showComposeTools: (try? c.decodeIfPresent(Bool.self, forKey: .showComposeTools)) ?? d.showComposeTools,
            reportCurrentFolder: (try? c.decodeIfPresent(Bool.self, forKey: .reportCurrentFolder))
                ?? d.reportCurrentFolder,
            wordEditing: (try? c.decodeIfPresent(WordEditingSettings.self, forKey: .wordEditing)) ?? d.wordEditing,
            optionalChipIDs: (try? c.decodeIfPresent([String].self, forKey: .optionalChipIDs)) ?? d.optionalChipIDs,
            sessionBackend: (try? c.decodeIfPresent(SessionBackend.self, forKey: .sessionBackend)) ?? d.sessionBackend,
            sessionTimeouts: (try? c.decodeIfPresent(SessionTimeouts.self, forKey: .sessionTimeouts)) ?? d.sessionTimeouts,
            tabTitles: (try? c.decodeIfPresent(TabTitleSettings.self, forKey: .tabTitles)) ?? d.tabTitles)
    }
}

/// Keeps `TerminalPreferences` as JSON in UserDefaults.
public struct TerminalPreferencesStore: @unchecked Sendable {
    public static let key = "rssh.terminalPreferences"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved preferences, or the defaults when none are saved or they cannot be read.
    public func load() -> TerminalPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let prefs = try? JSONDecoder().decode(TerminalPreferences.self, from: data) else { return TerminalPreferences() }
        return prefs
    }

    public func save(_ preferences: TerminalPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
