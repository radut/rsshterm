import RSSHKit

/// About › Legal of the Linux app: the app's own line, then one section per third-party component (the generated
/// RSSHKit ThirdPartyNotices list) with its full licence and NOTICE texts. AdwAboutDialog renders copyright and licence
/// as Pango markup, so every text here is escaped.
public enum LegalSections {
    public struct Section: Equatable, Sendable {
        public let title: String
        /// Pango markup (escaped).
        public let copyright: String
        /// Pango markup (escaped).
        public let license: String
    }

    public static let appCopyright = "© 2026 rSshTerm authors"

    /// The app's own licence line; the AppImage adds where its bundled system libraries' notices are.
    public static func appLicense(isAppImage: Bool) -> String {
        var text = "Third-party software in rSshTerm and its licences are listed below and in "
            + "/usr/share/doc/rsshterm/THIRD_PARTY_NOTICES."
        if isAppImage {
            text += " This AppImage also bundles shared libraries from Ubuntu (GTK 4, libadwaita, VTE, GLib, FreeRDP, "
                + "libusb and their dependencies, LGPL and other licences): their copyright files, package versions and "
                + "the written offer for their source code are in usr/share/doc/rsshterm/bundled-libraries/ inside "
                + "the AppImage (run it with --appimage-extract)."
        }
        return escape(text)
    }

    public static func sections(for platform: ThirdPartyPlatform = .linux) -> [Section] {
        ThirdPartyNotices.components(for: platform).map { component in
            var lines = ["Licence: \(component.license)"]
            if !component.url.isEmpty { lines.append(component.url) }
            if !component.changes.isEmpty { lines.append(component.changes) }
            if !component.acknowledgement.isEmpty { lines.append(component.acknowledgement) }
            let bodies = ThirdPartyNotices.texts(of: component).map(\.body)
            return Section(title: component.title,
                           copyright: escape(lines.joined(separator: "\n")),
                           license: escape(bodies.joined(separator: "\n\n")))
        }
    }

    /// Pango/GMarkup escaping (what g_markup_escape_text does for these five characters).
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}
