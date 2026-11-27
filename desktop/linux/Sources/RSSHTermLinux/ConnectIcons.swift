import Foundation
import RSSHKit

/// The "How to connect" glyphs of the Linux app: plain 16 px symbolic SVGs drawn here (a terminal, a display, two
/// overlapping screens, a window with a title bar), the same shapes as the SF Symbols the Apple apps use. No
/// vendor logos. Written once into an icon-theme folder the app adds to GTK's search path, so GTK recolours them
/// like any `-symbolic` icon.
public enum ConnectIcons {
    public static func svg(for service: ConnectService) -> String {
        let body: String
        switch service {
        case .ssh:
            body = """
            <path d="M2.5 1A2.5 2.5 0 0 0 0 3.5v9A2.5 2.5 0 0 0 2.5 15h11a2.5 2.5 0 0 0 2.5-2.5v-9A2.5 2.5 0 0 0 13.5 1zm0 1.5h11a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1z"/>\
            <path d="M3.47 5.03 5.94 7.5 3.47 9.97l1.06 1.06L8.06 7.5 4.53 3.97zM8 10h5v1.5H8z"/>
            """
        case .rdp:
            body = """
            <path d="M2 1.5A2 2 0 0 0 0 3.5v7a2 2 0 0 0 2 2h4.25v1.5H4V15.5h8V14H9.75v-1.5H14a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2zm0 1.5h12a.5.5 0 0 1 .5.5v7a.5.5 0 0 1-.5.5H2a.5.5 0 0 1-.5-.5v-7A.5.5 0 0 1 2 3z"/>
            """
        case .vnc:
            body = """
            <path d="M4.5 1A1.5 1.5 0 0 0 3 2.5V4h1.5V2.5h9v6H12V10h1.5A1.5 1.5 0 0 0 15 8.5v-6A1.5 1.5 0 0 0 13.5 1z"/>\
            <path d="M2.5 5A1.5 1.5 0 0 0 1 6.5v6A1.5 1.5 0 0 0 2.5 14h9a1.5 1.5 0 0 0 1.5-1.5v-6A1.5 1.5 0 0 0 11.5 5zm0 1.5h9v6h-9z"/>
            """
        case .screenSharing:
            body = """
            <path d="M2.5 1.5A2.5 2.5 0 0 0 0 4v8a2.5 2.5 0 0 0 2.5 2.5h11A2.5 2.5 0 0 0 16 12V4a2.5 2.5 0 0 0-2.5-2.5zM1.5 6h13v6a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1z"/>\
            <circle cx="3" cy="3.75" r=".75" fill="#fff"/><circle cx="5" cy="3.75" r=".75" fill="#fff"/><circle cx="7" cy="3.75" r=".75" fill="#fff"/>
            """
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"#2e3436\">\(body)</svg>\n"
    }

    /// The broadcast badge: a dot with radio waves on both sides (SF Symbol dot.radiowaves.left.and.right).
    public static let broadcastIconName = "rssh-broadcast-symbolic"

    public static let broadcastSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="none" \
        stroke="#2e3436" stroke-width="1.5" stroke-linecap="round"><circle cx="8" cy="8" r="1.75" fill="#2e3436" \
        stroke="none"/><path d="M5.2 5.2a4 4 0 0 0 0 5.6M10.8 5.2a4 4 0 0 1 0 5.6M3 3a7.1 7.1 0 0 0 0 10M13 3a7.1 7.1 0 0 1 \
        0 10"/></svg>

        """

    /// Writes the icons under `root` (hicolor/scalable/actions/<name>.svg) and returns `root` for
    /// gtk_icon_theme_add_search_path. Rewrites a file only when its content differs.
    @discardableResult
    public static func install(into root: URL) throws -> URL {
        let dir = root.appendingPathComponent("hicolor/scalable/actions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for service in ConnectService.allCases {
            let file = dir.appendingPathComponent("\(service.iconName).svg")
            let data = Data(svg(for: service).utf8)
            if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
        }
        let badge = dir.appendingPathComponent("\(broadcastIconName).svg"), data = Data(broadcastSVG.utf8)
        if (try? Data(contentsOf: badge)) != data { try data.write(to: badge, options: .atomic) }
        return root
    }

    /// $XDG_CACHE_HOME/rsshterm/icons (else ~/.cache/rsshterm/icons).
    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let cache = environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return cache.appendingPathComponent("rsshterm/icons", isDirectory: true)
    }
}
