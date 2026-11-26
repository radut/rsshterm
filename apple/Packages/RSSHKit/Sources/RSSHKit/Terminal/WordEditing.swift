/// How word and line editing keys behave (Settings › Keyboard › Word Editing). Ctrl+arrows always send xterm codes;
/// the preset decides what Option and Cmd do on a hardware keyboard and what the long-press keys on screen send.
public struct WordEditingSettings: Codable, Hashable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Sendable {
        /// iTerm2's "Natural Text Editing": Option moves by word (ESC b / ESC f), Cmd by line (Ctrl-A / Ctrl-E).
        case natural
        /// A PC keyboard in GNOME Terminal or Konsole: Option is Alt and sends xterm codes (ESC[1;3D), Cmd is left alone.
        case linux
    }

    /// What Ctrl+Backspace sends.
    public enum CtrlBackspace: String, Codable, CaseIterable, Sendable {
        /// Ctrl-W (0x17): readline's unix-word-rubout, in every shell's default keymap.
        case ctrlW
        /// ^H (0x08), what xterm sends; bash and zsh treat it as one backspace.
        case ctrlH
    }

    /// What Ctrl+Delete (forward delete) sends.
    public enum CtrlDelete: String, Codable, CaseIterable, Sendable {
        /// `ESC [ 3 ; 5 ~`, the xterm code; readline kills a word only where inputrc maps it.
        case xterm
        /// `ESC d`: readline's kill-word in the default emacs keymap.
        case escD
    }

    /// Which Option key types ESC + letter (Meta) instead of the special character (å, ∫, …).
    public enum OptionMeta: String, Codable, CaseIterable, Sendable {
        case off, left, right, both
    }

    public var preset: Preset
    public var ctrlBackspace: CtrlBackspace
    public var ctrlDelete: CtrlDelete
    public var optionAsMeta: OptionMeta

    public init(preset: Preset = .natural, ctrlBackspace: CtrlBackspace = .ctrlW, ctrlDelete: CtrlDelete = .xterm,
                optionAsMeta: OptionMeta = .both) {
        self.preset = preset
        self.ctrlBackspace = ctrlBackspace
        self.ctrlDelete = ctrlDelete
        self.optionAsMeta = optionAsMeta
    }

    /// Missing or unknown values take their defaults, so settings from another build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WordEditingSettings()
        self.init(preset: (try? c.decodeIfPresent(Preset.self, forKey: .preset)) ?? d.preset,
                  ctrlBackspace: (try? c.decodeIfPresent(CtrlBackspace.self, forKey: .ctrlBackspace)) ?? d.ctrlBackspace,
                  ctrlDelete: (try? c.decodeIfPresent(CtrlDelete.self, forKey: .ctrlDelete)) ?? d.ctrlDelete,
                  optionAsMeta: (try? c.decodeIfPresent(OptionMeta.self, forKey: .optionAsMeta)) ?? d.optionAsMeta)
    }

    /// Whether Option held on `side` makes Option+letter send ESC + letter.
    public func isMeta(_ side: OptionSide) -> Bool {
        switch optionAsMeta {
        case .off: return false
        case .both: return true
        case .left: return side != .right
        case .right: return side != .left
        }
    }
}

/// Which Option key is down. `.unknown` when the keyboard does not say (counts as either side).
public enum OptionSide: Hashable, Sendable {
    case left, right, unknown
}

/// A word or line editing command, as the long-press keys on screen and the shortcut list name them.
public enum WordEdit: String, Hashable, Sendable, CaseIterable {
    case wordLeft, wordRight, deleteWordBack, deleteWordForward
    case lineStart, lineEnd, deleteToLineStart, deleteToLineEnd

    /// The bytes for this command under `settings`.
    public func bytes(_ settings: WordEditingSettings) -> [UInt8] {
        let natural = settings.preset == .natural
        switch self {
        case .wordLeft: return natural ? [0x1B, 0x62] : KeyEncoder.encode(.left, modifiers: .ctrl)
        case .wordRight: return natural ? [0x1B, 0x66] : KeyEncoder.encode(.right, modifiers: .ctrl)
        case .deleteWordBack: return natural ? [0x1B, 0x7F] : HardwareKeyMap.ctrlBackspace(settings)
        case .deleteWordForward: return natural ? [0x1B, 0x64] : HardwareKeyMap.ctrlDelete(settings)
        case .lineStart: return [0x01]
        case .lineEnd: return [0x05]
        case .deleteToLineStart: return [0x15]
        case .deleteToLineEnd: return [0x0B]
        }
    }

    /// Plain words for the help sheet and VoiceOver.
    public var title: String {
        switch self {
        case .wordLeft: return "Word left"
        case .wordRight: return "Word right"
        case .deleteWordBack: return "Delete word before cursor"
        case .deleteWordForward: return "Delete word after cursor"
        case .lineStart: return "Start of line"
        case .lineEnd: return "End of line"
        case .deleteToLineStart: return "Delete to start of line"
        case .deleteToLineEnd: return "Delete to end of line"
        }
    }
}
