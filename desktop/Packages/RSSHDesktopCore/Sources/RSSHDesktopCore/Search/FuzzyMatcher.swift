import Foundation

/// fzf-style subsequence scoring: every query character must appear in order. Matches at the start of the text or
/// of a word, and runs of consecutive characters, score more; gaps cost a little; an exact or prefix match wins.
public enum FuzzyMatcher {
    /// Nil when `query` is not a subsequence of `text` (both compared case-insensitively). An empty query scores 0.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        guard q.count <= t.count else { return nil }
        let original = Array(text)

        var total = 0
        var ti = 0
        var previousMatch: Int?
        for qc in q {
            guard let found = t[ti...].firstIndex(of: qc) else { return nil }
            var points = 1
            if found == 0 { points += 8 } else if isWordStart(original, found) { points += 6 }
            if let previous = previousMatch {
                if found == previous + 1 { points += 5 } else { points -= min(found - previous - 1, 3) }
            }
            total += points
            previousMatch = found
            ti = found + 1
        }
        if t == q { total += 20 } else if t.starts(with: q) { total += 10 }
        return total
    }

    /// After a separator, or a lower→upper case change (camelCase).
    private static func isWordStart(_ text: [Character], _ index: Int) -> Bool {
        let before = text[index - 1]
        if !(before.isLetter || before.isNumber) { return true }
        return before.isLowercase && text[index].isUppercase
    }
}
