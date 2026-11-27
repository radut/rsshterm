/// What a button on the extra key row or the chip bar does.
public enum KeyAction: Hashable, Sendable {
    /// A key, with the latched modifiers applied.
    case key(TerminalKey)
    /// Literal text (a symbol), with the latched modifiers applied.
    case text(String)
    /// A fixed combination (Ctrl+C), merged with whatever is latched.
    case combo(TerminalKey, KeyModifiers)
    /// Toggle a sticky modifier.
    case latch(KeyModifiers)
    /// Paste the clipboard (the app reads it; this layer only names the action).
    case paste
    /// Cycle the extra key row to its next page.
    case morePages
    /// A word or line editing command; its bytes depend on Settings › Keyboard › Word Editing.
    case wordEdit(WordEdit)

    /// The bytes to send and the latch afterwards.
    public func resolve(latch: ModifierLatch, applicationCursor: Bool,
                        wordEditing: WordEditingSettings = WordEditingSettings()) -> (bytes: [UInt8], latch: ModifierLatch) {
        switch self {
        case .key(let key):
            return (KeyEncoder.encode(key, modifiers: latch.active, applicationCursor: applicationCursor), latch.consumed())
        case .text(let text):
            return (KeyEncoder.encodeTyped(text, modifiers: latch.active), latch.consumed())
        case .combo(let key, let mods):
            let all = mods.union(latch.active)
            return (KeyEncoder.encode(key, modifiers: all, applicationCursor: applicationCursor), latch.consumed())
        case .latch(let modifier):
            return ([], latch.tapped(modifier))
        case .wordEdit(let edit):
            return (edit.bytes(wordEditing), latch.consumed())
        case .paste, .morePages:
            return ([], latch)
        }
    }
}

/// One button.
public struct ExtraKey: Hashable, Sendable, Identifiable {
    public var label: String
    /// SF Symbol name to show instead of the label, when there is a fitting one.
    public var symbol: String?
    public var accessibilityName: String
    public var action: KeyAction
    /// What holding the button does, when it does something else than a tap (← holds for word left).
    public var longPress: KeyAction?

    public var id: String { label + "|" + accessibilityName }

    public init(_ label: String, symbol: String? = nil, name: String? = nil, _ action: KeyAction,
                longPress: KeyAction? = nil) {
        self.label = label
        self.symbol = symbol
        self.accessibilityName = name ?? label
        self.action = action
        self.longPress = longPress
    }
}

/// A page the "…" button switches to.
public struct ExtraKeyPage: Hashable, Sendable, Identifiable {
    public var title: String
    public var keys: [ExtraKey]
    public var id: String { title }
}

/// The extra key row above the keyboard and the chip bar. Data only; the app draws it.
public enum ExtraKeyLayout {
    public static let mainRow: [ExtraKey] = [
        ExtraKey("esc", name: "Escape", .key(.escape)),
        ExtraKey("ctrl", name: "Control", .latch(.ctrl)),
        ExtraKey("tab", name: "Tab", .key(.tab)),
        ExtraKey("←", symbol: "arrow.left", name: "Left", .key(.left), longPress: .wordEdit(.wordLeft)),
        ExtraKey("↑", symbol: "arrow.up", name: "Up", .key(.up)),
        ExtraKey("↓", symbol: "arrow.down", name: "Down", .key(.down)),
        ExtraKey("→", symbol: "arrow.right", name: "Right", .key(.right), longPress: .wordEdit(.wordRight)),
        ExtraKey("⏎", symbol: "return", name: "Enter", .key(.enter)),
        ExtraKey("…", symbol: "ellipsis", name: "More keys", .morePages),
    ]

    /// What "…" cycles through: symbols, then navigation. F1–F12 are on the Fn row (the Fn chip), not here.
    public static let pages: [ExtraKeyPage] = [
        ExtraKeyPage(title: "Symbols", keys: ["/", "-", "|", "@", "~", ".", ":", ";", "_", "\\", "$", "*", "&"]
            .map { ExtraKey($0, .text($0)) }),
        ExtraKeyPage(title: "Navigation", keys: [
            ExtraKey("PgUp", name: "Page up", .key(.pageUp)),
            ExtraKey("PgDn", name: "Page down", .key(.pageDown)),
            ExtraKey("Home", .key(.home)),
            ExtraKey("End", .key(.end)),
            ExtraKey("Del", name: "Delete", .key(.delete)),
            ExtraKey("Ins", name: "Insert", .key(.insert)),
            ExtraKey("META", name: "Meta (Alt)", .latch(.alt)),
        ]),
    ]

    /// The optional row above the extra key row (Settings › Keyboard › Function Key Row).
    public static let functionRow: [ExtraKey] = (1...12).map { ExtraKey("F\($0)", .key(.function($0))) }

    /// The chips right above the keyboard: what the key row does not already have (esc, ctrl, tab are there).
    public static let chips: [ExtraKey] = [
        ExtraKey("Paste", symbol: "doc.on.clipboard", .paste),
        ExtraKey("#", name: "Hash", .text("#")),
        ExtraKey("$", name: "Dollar", .text("$")),
        ExtraKey("`", name: "Backtick", .text("`")),
        ExtraKey("~", name: "Tilde", .text("~")),
        ExtraKey("|", name: "Pipe", .text("|")),
        ExtraKey("Ctrl+C", name: "Control C, interrupt", .combo(.character("c"), .ctrl)),
        ExtraKey("Ctrl+D", name: "Control D, end of input", .combo(.character("d"), .ctrl)),
        ExtraKey("Ctrl+L", name: "Control L, clear screen", .combo(.character("l"), .ctrl)),
    ]

    /// Chips Settings › Keyboard can add after the fixed ones, keyed by a stable id, in this order.
    public static let optionalChips: [(id: String, key: ExtraKey)] = [
        ("backspace", ExtraKey("⌫", symbol: "delete.left", name: "Backspace, hold to delete a word",
                               .key(.backspace), longPress: .wordEdit(.deleteWordBack))),
        ("ctrlW", ExtraKey("Ctrl+W", name: "Control W, delete word", .combo(.character("w"), .ctrl))),
        ("ctrlU", ExtraKey("Ctrl+U", name: "Control U, delete to start of line", .combo(.character("u"), .ctrl))),
        ("ctrlA", ExtraKey("Ctrl+A", name: "Control A, start of line", .combo(.character("a"), .ctrl))),
        ("ctrlE", ExtraKey("Ctrl+E", name: "Control E, end of line", .combo(.character("e"), .ctrl))),
    ]

    /// The optional chips on by default.
    public static let defaultOptionalChipIDs = ["backspace"]

    /// The fixed chips plus the optional ones whose id is in `enabled`, in layout order.
    public static func chips(enabled: [String]) -> [ExtraKey] {
        chips + optionalChips.filter { enabled.contains($0.id) }.map(\.key)
    }
}
