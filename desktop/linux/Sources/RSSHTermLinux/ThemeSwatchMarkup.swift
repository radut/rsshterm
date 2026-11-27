import Foundation
import RSSHKit

/// Pango markup that draws a theme in its own colours, for the Preferences theme gallery: a swatch per row and a
/// larger live preview of the chosen theme.
public enum ThemeSwatchMarkup {
    /// " Aa " in the foreground over the background, then the 8 normal ANSI colours as blocks.
    public static func swatch(_ scheme: TerminalColorScheme) -> String {
        let blocks = scheme.ansi.prefix(8).map { span("█", fg: $0, bg: scheme.background) }.joined()
        return "<tt>" + span(" Aa ", fg: scheme.foreground, bg: scheme.background) + blocks
            + span(" ", fg: scheme.foreground, bg: scheme.background) + "</tt>"
    }

    /// A prompt, `git status -s`, a diff and the 16 ANSI colours, each line padded to `width` columns so the
    /// background reads as one block.
    public static func preview(_ scheme: TerminalColorScheme, width: Int = 44) -> String {
        let lines: [[(String, Int?)]] = [
            [("you@web-1", 2), (":", 7), ("~/app", 4), ("$ git status -s", nil)],
            [(" M ", 3), ("main.go  ", nil), ("?? ", 1), ("notes.txt", 1)],
            [("+ added line  ", 2), ("- removed line", 1)],
            [("-> != >= => ", 5), ("{} [] 0O 1lI", 6)],
        ]
        var out = lines.map { runs -> String in
            let used = runs.reduce(0) { $0 + $1.0.count }
            let body = runs.map { span($0.0, fg: $0.1.map { scheme.ansi[$0] } ?? scheme.foreground, bg: scheme.background) }
            return span(" ", fg: scheme.foreground, bg: scheme.background) + body.joined()
                + span(String(repeating: " ", count: max(0, width - used - 1)), fg: scheme.foreground, bg: scheme.background)
        }
        let palette = scheme.ansi.map { span("██", fg: $0, bg: scheme.background) }.joined()
        out.append(span(" ", fg: scheme.foreground, bg: scheme.background) + palette
            + span(String(repeating: " ", count: max(0, width - 33)), fg: scheme.foreground, bg: scheme.background))
        return "<tt>" + out.joined(separator: "\n") + "</tt>"
    }

    private static func span(_ text: String, fg: String, bg: String) -> String {
        "<span foreground=\"\(fg)\" background=\"\(bg)\" fgalpha=\"100%\" bgalpha=\"100%\">\(escape(text))</span>"
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
