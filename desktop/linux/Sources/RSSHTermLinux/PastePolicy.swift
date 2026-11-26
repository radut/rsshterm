import Foundation

/// When a paste into several panes at once asks first: whenever the text could run something on its own. Any line
/// end (LF, CR, NEL, LS, PS: a terminal executes on CR) or control character other than tab counts, including ESC,
/// which could end bracketed paste early.
public enum PastePolicy {
    public static func needsConfirmation(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.newlines.contains(scalar) || (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7f
        }
    }
}
