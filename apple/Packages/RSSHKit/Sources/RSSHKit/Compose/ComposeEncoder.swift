import Foundation

/// How the compose bar sends its text.
public enum ComposeMode: String, Codable, CaseIterable, Sendable {
    /// Typed at the prompt: each line runs, Enter follows.
    case command
    /// Written into whatever runs (nano, vim, a heredoc): one bracketed paste when the remote enabled it.
    case text

    /// Whether Send presses Enter after the text, unless the user flips it.
    public var defaultAppendsEnter: Bool { self == .command }
}

/// A key the draft holds as a visible token (from a spoken shortcut or typed by hand), pressed when it is sent.
public enum ComposeKey: String, CaseIterable, Sendable {
    case enter = "⏎"
    case tab = "⇥"
    case interrupt = "⌃C"

    public var token: String { rawValue }

    /// Characters that start a token. Text that comes from outside the user's typing (a path, scanned text) has
    /// them removed, so it can never press a key.
    public static let tokenCharacters: Set<Character> = ["⏎", "⇥", "⌃"]

    /// `text` without token characters.
    public static func literal(_ text: String) -> String {
        String(text.filter { !tokenCharacters.contains($0) })
    }

    var bytes: [UInt8] {
        switch self {
        case .enter: [0x0D]
        case .tab: [0x09]
        case .interrupt: [0x03]
        }
    }
}

/// One run of a draft: text, or a key between texts.
public enum ComposeSegment: Equatable, Sendable {
    case text(String)
    case key(ComposeKey)
}

/// Turns the compose bar's draft into terminal bytes. Pure: the app passes the remote's bracketed-paste state.
public enum ComposeEncoder {
    /// Splits a draft at its key tokens. Empty text runs are dropped.
    public static func segments(of draft: String) -> [ComposeSegment] {
        var out: [ComposeSegment] = []
        var text = ""
        var rest = Substring(draft)
        while !rest.isEmpty {
            if let key = ComposeKey.allCases.first(where: { rest.hasPrefix($0.token) }) {
                if !text.isEmpty { out.append(.text(text)); text = "" }
                out.append(.key(key))
                rest = rest.dropFirst(key.token.count)
            } else {
                text.append(rest.removeFirst())
            }
        }
        if !text.isEmpty { out.append(.text(text)) }
        return out
    }

    /// The bytes Send writes. Text goes through `KeyEncoder.paste` (control characters dropped, newlines as CR), so a
    /// draft can never smuggle escape sequences; in `.text` mode each text run is bracketed when `bracketedPaste` is
    /// on. Key tokens are pressed between the runs, outside any bracket.
    public static func encode(_ draft: String, mode: ComposeMode, appendEnter: Bool, bracketedPaste: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        for segment in segments(of: draft) {
            switch segment {
            case .text(let text):
                bytes += KeyEncoder.paste(text, bracketed: mode == .text && bracketedPaste)
            case .key(let key):
                bytes += key.bytes
            }
        }
        if appendEnter { bytes.append(0x0D) }
        return bytes
    }
}
