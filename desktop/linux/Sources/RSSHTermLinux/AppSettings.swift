import Foundation
import RSSHKit

/// The Linux app's own settings (Preferences, plus what it remembers): `$XDG_CONFIG_HOME/rssh/desktop.json`, 0600.
/// Unknown keys are ignored and missing or bad values keep their defaults, so an older or newer file never breaks a
/// launch.
public struct AppSettings: Codable, Equatable, Sendable {
    public enum ColorScheme: String, Codable, CaseIterable, Sendable { case system, light, dark }

    public static let maximumScrollback = 1_000_000

    /// A Pango font description, as GtkFontDialogButton writes it.
    public var fontName = "Monospace 11"
    public var colorScheme = ColorScheme.system
    public var scrollbackLines: Int {
        get { storedScrollback }
        set { storedScrollback = min(max(newValue, 0), Self.maximumScrollback) }
    }
    public var autoInstallUpdates = true
    /// The "add the Include to ~/.ssh/config?" question was asked (answered either way): never ask again.
    public var includeOffered = false
    public var lastUpdateCheck: Date?
    /// Reopen the windows, tabs and splits of the last run (local shells in their last directory).
    public var restoreSession = true
    /// Striped background on every pane in the broadcast, the one typed in too (the badge shows either way).
    public var broadcastIndicator = true
    /// The server sidebar is shown (F9 toggles).
    public var showSidebar = true
    /// Settings › Tab Titles: the two templates and the one-line option.
    public var tabTitles = TabTitleSettings()
    /// The terminal theme (RSSHKit TerminalColorSchemes id) when the style is dark or follows the system, and when
    /// it is forced light. A server's own theme wins over both.
    public var darkThemeID = TerminalColorSchemes.defaultDark.id
    public var lightThemeID = TerminalColorSchemes.defaultLight.id

    /// The theme a pane without a server theme shows: the light one only when Preferences forces Light (System keeps
    /// the black default, as before). An id no longer known falls back to the default.
    public var terminalScheme: TerminalColorScheme {
        colorScheme == .light
            ? TerminalColorSchemes.scheme(id: lightThemeID) ?? TerminalColorSchemes.defaultLight
            : TerminalColorSchemes.scheme(id: darkThemeID) ?? TerminalColorSchemes.defaultDark
    }

    private var storedScrollback = 10_000

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case fontName, colorScheme, scrollbackLines, autoInstallUpdates, includeOffered, lastUpdateCheck, restoreSession, broadcastIndicator, showSidebar, tabTitles, darkThemeID, lightThemeID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(String.self, forKey: .fontName), !v.isEmpty { fontName = v }
        if let v = try? c.decode(ColorScheme.self, forKey: .colorScheme) { colorScheme = v }
        if let v = try? c.decode(Int.self, forKey: .scrollbackLines) { scrollbackLines = v }
        if let v = try? c.decode(Bool.self, forKey: .autoInstallUpdates) { autoInstallUpdates = v }
        if let v = try? c.decode(Bool.self, forKey: .includeOffered) { includeOffered = v }
        lastUpdateCheck = try? c.decode(Date.self, forKey: .lastUpdateCheck)
        if let v = try? c.decode(Bool.self, forKey: .restoreSession) { restoreSession = v }
        if let v = try? c.decode(Bool.self, forKey: .broadcastIndicator) { broadcastIndicator = v }
        if let v = try? c.decode(Bool.self, forKey: .showSidebar) { showSidebar = v }
        if let v = try? c.decode(TabTitleSettings.self, forKey: .tabTitles) { tabTitles = v }
        if let v = try? c.decode(String.self, forKey: .darkThemeID), !v.isEmpty { darkThemeID = v }
        if let v = try? c.decode(String.self, forKey: .lightThemeID), !v.isEmpty { lightThemeID = v }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(colorScheme, forKey: .colorScheme)
        try c.encode(scrollbackLines, forKey: .scrollbackLines)
        try c.encode(autoInstallUpdates, forKey: .autoInstallUpdates)
        try c.encode(includeOffered, forKey: .includeOffered)
        try c.encodeIfPresent(lastUpdateCheck, forKey: .lastUpdateCheck)
        try c.encode(restoreSession, forKey: .restoreSession)
        try c.encode(broadcastIndicator, forKey: .broadcastIndicator)
        try c.encode(showSidebar, forKey: .showSidebar)
        try c.encode(tabTitles, forKey: .tabTitles)
        try c.encode(darkThemeID, forKey: .darkThemeID)
        try c.encode(lightThemeID, forKey: .lightThemeID)
    }

    public static func defaultURL(environment: [String: String], home: String = NSHomeDirectory()) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "\(home)/.config"
        return URL(fileURLWithPath: "\(base)/rssh/desktop.json")
    }

    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
