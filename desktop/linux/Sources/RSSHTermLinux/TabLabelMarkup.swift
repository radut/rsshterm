import Foundation
import RSSHKit

/// A tab's two lines as Pango markup: the title bold, the subtitle smaller under it (or the one-line form).
public enum TabLabelMarkup {
    public static func markup(_ label: TabTitleLabel, singleLine: Bool) -> String {
        if singleLine { return escape(label.singleLine) }
        let title = "<b>\(escape(label.title))</b>"
        return label.subtitle.isEmpty ? title : title + "\n<small>\(escape(label.subtitle))</small>"
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
