import Foundation

/// The few words dictation turns into keys when "Command mode" is on. They only edit the draft (a newline, or a key
/// token that `ComposeEncoder` presses on Send); nothing is sent until the user taps Send.
public enum SpokenShortcuts {
    /// Phrase -> replacement, longest phrases first so "control c" wins over a bare word.
    public static let phrases: [(words: [String], replacement: String)] = [
        (["new", "line"], "\n"),
        (["newline"], "\n"),
        (["control", "c"], ComposeKey.interrupt.token),
        (["control", "see"], ComposeKey.interrupt.token),
        (["ctrl", "c"], ComposeKey.interrupt.token),
        (["enter"], ComposeKey.enter.token),
        (["tab"], ComposeKey.tab.token),
    ]

    /// What the help popover lists.
    public static let help: [(say: String, does: String)] = [
        ("new line", "starts a new line in the draft"),
        ("enter", "presses Enter at that point when you send (⏎)"),
        ("tab", "presses Tab, for completion (⇥)"),
        ("control C", "presses Ctrl+C, to interrupt (⌃C)"),
    ]

    /// Replaces the phrases in a transcript. Words are matched case-insensitively, ignoring punctuation the
    /// recogniser attaches ("Enter." or "Control-C"); the spaces around a replacement are dropped.
    public static func apply(to transcript: String) -> String {
        let words = transcript.split(whereSeparator: \.isWhitespace).flatMap(splitHyphen)
        var out = ""
        var index = 0
        var lastWasReplacement = false
        while index < words.count {
            if let match = phrases.first(where: { matches($0.words, words, at: index) }) {
                out = trimmingTrailingSpace(out) + match.replacement
                index += match.words.count
                lastWasReplacement = true
                continue
            }
            if !out.isEmpty, !lastWasReplacement { out += " " }
            out += words[index]
            lastWasReplacement = false
            index += 1
        }
        return out
    }

    private static func splitHyphen(_ word: Substring) -> [String] {
        let lowered = normalized(String(word))
        if lowered == "control-c" || lowered == "ctrl-c" { return word.split(separator: "-").map(String.init) }
        return [String(word)]
    }

    private static func matches(_ phrase: [String], _ words: [String], at index: Int) -> Bool {
        guard index + phrase.count <= words.count else { return false }
        return phrase.enumerated().allSatisfy { normalized(words[index + $0.offset]) == $0.element }
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-")))
    }

    private static func trimmingTrailingSpace(_ text: String) -> String {
        var text = text
        while text.last == " " { text.removeLast() }
        return text
    }
}
