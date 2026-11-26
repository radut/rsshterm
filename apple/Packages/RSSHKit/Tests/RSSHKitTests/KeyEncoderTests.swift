import Testing
@testable import RSSHKit

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
private let esc: UInt8 = 0x1B

@Suite struct KeyEncoderTests {
    // MARK: plain keys

    @Test func plainCharactersAreUTF8() {
        #expect(KeyEncoder.encode(.character("a")) == bytes("a"))
        #expect(KeyEncoder.encode(.character("é")) == bytes("é"))
    }

    @Test func specialKeys() {
        #expect(KeyEncoder.encode(.escape) == [esc])
        #expect(KeyEncoder.encode(.tab) == [0x09])
        #expect(KeyEncoder.encode(.enter) == [0x0D])
        #expect(KeyEncoder.encode(.backspace) == [0x7F])
        #expect(KeyEncoder.encode(.delete) == bytes("\u{1B}[3~"))
        #expect(KeyEncoder.encode(.insert) == bytes("\u{1B}[2~"))
    }

    @Test func arrowsNormalAndApplicationCursorMode() {
        #expect(KeyEncoder.encode(.up) == bytes("\u{1B}[A"))
        #expect(KeyEncoder.encode(.down) == bytes("\u{1B}[B"))
        #expect(KeyEncoder.encode(.right) == bytes("\u{1B}[C"))
        #expect(KeyEncoder.encode(.left) == bytes("\u{1B}[D"))
        #expect(KeyEncoder.encode(.up, applicationCursor: true) == bytes("\u{1B}OA"))
        #expect(KeyEncoder.encode(.left, applicationCursor: true) == bytes("\u{1B}OD"))
    }

    @Test func navigationKeys() {
        #expect(KeyEncoder.encode(.home) == bytes("\u{1B}[H"))
        #expect(KeyEncoder.encode(.end) == bytes("\u{1B}[F"))
        #expect(KeyEncoder.encode(.home, applicationCursor: true) == bytes("\u{1B}OH"))
        #expect(KeyEncoder.encode(.end, applicationCursor: true) == bytes("\u{1B}OF"))
        #expect(KeyEncoder.encode(.pageUp) == bytes("\u{1B}[5~"))
        #expect(KeyEncoder.encode(.pageDown) == bytes("\u{1B}[6~"))
    }

    @Test(arguments: [
        (1, "\u{1B}OP"), (2, "\u{1B}OQ"), (3, "\u{1B}OR"), (4, "\u{1B}OS"),
        (5, "\u{1B}[15~"), (6, "\u{1B}[17~"), (7, "\u{1B}[18~"), (8, "\u{1B}[19~"),
        (9, "\u{1B}[20~"), (10, "\u{1B}[21~"), (11, "\u{1B}[23~"), (12, "\u{1B}[24~"),
        (13, "\u{1B}[25~"), (14, "\u{1B}[26~"), (15, "\u{1B}[28~"), (16, "\u{1B}[29~"),
    ])
    func functionKeys(n: Int, expected: String) {
        #expect(KeyEncoder.encode(.function(n)) == bytes(expected))
    }

    @Test func functionKeyOutOfRangeSendsNothing() {
        #expect(KeyEncoder.encode(.function(0)).isEmpty)
        #expect(KeyEncoder.encode(.function(17)).isEmpty)
    }

    // MARK: ctrl

    @Test func ctrlLetters() {
        #expect(KeyEncoder.encode(.character("c"), modifiers: .ctrl) == [0x03])
        #expect(KeyEncoder.encode(.character("C"), modifiers: .ctrl) == [0x03])
        #expect(KeyEncoder.encode(.character("a"), modifiers: .ctrl) == [0x01])
        #expect(KeyEncoder.encode(.character("z"), modifiers: .ctrl) == [0x1A])
        #expect(KeyEncoder.encode(.character("d"), modifiers: .ctrl) == [0x04])
        #expect(KeyEncoder.encode(.character("l"), modifiers: .ctrl) == [0x0C])
    }

    @Test(arguments: [
        ("@", 0x00), (" ", 0x00), ("2", 0x00), ("[", 0x1B), ("3", 0x1B), ("\\", 0x1C), ("4", 0x1C),
        ("]", 0x1D), ("5", 0x1D), ("^", 0x1E), ("6", 0x1E), ("_", 0x1F), ("7", 0x1F), ("-", 0x1F),
        ("/", 0x1F), ("?", 0x7F), ("8", 0x7F),
    ] as [(Character, UInt8)])
    func ctrlSymbols(ch: Character, expected: UInt8) {
        #expect(KeyEncoder.encode(.character(ch), modifiers: .ctrl) == [expected])
    }

    @Test func ctrlOnUnmappableCharacterSendsItPlain() {
        #expect(KeyEncoder.encode(.character("é"), modifiers: .ctrl) == bytes("é"))
        #expect(KeyEncoder.encode(.character("1"), modifiers: .ctrl) == bytes("1"))
    }

    @Test func modifiedArrowsUseXtermParameters() {
        #expect(KeyEncoder.encode(.up, modifiers: .ctrl) == bytes("\u{1B}[1;5A"))
        #expect(KeyEncoder.encode(.left, modifiers: .alt) == bytes("\u{1B}[1;3D"))
        #expect(KeyEncoder.encode(.right, modifiers: .shift) == bytes("\u{1B}[1;2C"))
        #expect(KeyEncoder.encode(.down, modifiers: [.ctrl, .shift]) == bytes("\u{1B}[1;6B"))
        // Modifiers win over application cursor mode, as in xterm.
        #expect(KeyEncoder.encode(.up, modifiers: .ctrl, applicationCursor: true) == bytes("\u{1B}[1;5A"))
        #expect(KeyEncoder.encode(.home, modifiers: .ctrl) == bytes("\u{1B}[1;5H"))
    }

    @Test func modifiedTildeAndFunctionKeys() {
        #expect(KeyEncoder.encode(.pageUp, modifiers: .ctrl) == bytes("\u{1B}[5;5~"))
        #expect(KeyEncoder.encode(.delete, modifiers: .shift) == bytes("\u{1B}[3;2~"))
        #expect(KeyEncoder.encode(.function(1), modifiers: .ctrl) == bytes("\u{1B}[1;5P"))
        #expect(KeyEncoder.encode(.function(5), modifiers: .alt) == bytes("\u{1B}[15;3~"))
    }

    // MARK: alt and shift

    @Test func altPrefixesEscape() {
        #expect(KeyEncoder.encode(.character("b"), modifiers: .alt) == [esc] + bytes("b"))
        #expect(KeyEncoder.encode(.character("x"), modifiers: [.alt, .ctrl]) == [esc, 0x18])
        #expect(KeyEncoder.encode(.backspace, modifiers: .alt) == [esc, 0x7F])
        #expect(KeyEncoder.encode(.enter, modifiers: .alt) == [esc, 0x0D])
        #expect(KeyEncoder.encode(.escape, modifiers: .alt) == [esc, esc])
    }

    @Test func shiftUppercasesAndBackTabs() {
        #expect(KeyEncoder.encode(.character("a"), modifiers: .shift) == bytes("A"))
        #expect(KeyEncoder.encode(.tab, modifiers: .shift) == bytes("\u{1B}[Z"))
        #expect(KeyEncoder.encode(.character("q"), modifiers: [.shift, .alt]) == [esc] + bytes("Q"))
    }

    @Test func ctrlOnTabEnterBackspace() {
        #expect(KeyEncoder.encode(.tab, modifiers: .ctrl) == [0x09])
        #expect(KeyEncoder.encode(.backspace, modifiers: .ctrl) == [0x08])
        #expect(KeyEncoder.encode(.enter, modifiers: .ctrl) == [0x0D])
    }

    // MARK: typed text and paste

    @Test func typedTextAppliesModifiersToASingleCharacter() {
        #expect(KeyEncoder.encodeTyped("c", modifiers: .ctrl) == [0x03])
        #expect(KeyEncoder.encodeTyped("f", modifiers: .alt) == [esc] + bytes("f"))
        #expect(KeyEncoder.encodeTyped("ls", modifiers: []) == bytes("ls"))
        #expect(KeyEncoder.encodeTyped("\n", modifiers: []) == [0x0D])
    }

    @Test func typedTextWithModifiersAndSeveralCharactersOnlyAltApplies() {
        #expect(KeyEncoder.encodeTyped("ab", modifiers: .ctrl) == bytes("ab"))
        #expect(KeyEncoder.encodeTyped("ab", modifiers: .alt) == [esc] + bytes("ab"))
    }

    @Test func pasteIsBracketedOnlyWhenTheTerminalAsks() {
        #expect(KeyEncoder.paste("echo hi\n", bracketed: false) == bytes("echo hi\r"))
        #expect(KeyEncoder.paste("x", bracketed: true) == bytes("\u{1B}[200~x\u{1B}[201~"))
        #expect(KeyEncoder.paste("a\r\nb", bracketed: false) == bytes("a\rb"))
    }

    @Test func pasteDropsControlCharactersButKeepsTabAndNewline() {
        #expect(KeyEncoder.paste("a\tb\u{07}c\u{7F}d\u{00}\n", bracketed: false) == bytes("a\tbcd\r"))
        #expect(KeyEncoder.paste("\u{1B}[A", bracketed: false) == bytes("[A"))
        #expect(KeyEncoder.paste("é ✓", bracketed: true) == bytes("\u{1B}[200~é ✓\u{1B}[201~"))
    }

    @Test func pasteStripsEmbeddedBracketEndToPreventEscape() {
        #expect(KeyEncoder.paste("a\u{1B}[201~b", bracketed: true) == bytes("\u{1B}[200~a[201~b\u{1B}[201~"))
        // A nested marker must not survive: every ESC and C1 control is dropped.
        let nested = KeyEncoder.paste("x\u{1B}[20\u{1B}[201~1~rm -rf ~\n", bracketed: true)
        #expect(nested == bytes("\u{1B}[200~x[20[201~1~rm -rf ~\r\u{1B}[201~"))
        #expect(KeyEncoder.paste("a\u{9B}201~b", bracketed: true) == bytes("\u{1B}[200~a201~b\u{1B}[201~"))
    }
}
