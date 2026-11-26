import Testing
@testable import RSSHKit

@Suite struct ComposeEncoderTests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private let open: [UInt8] = [0x1B, 0x5B] + Array("200~".utf8)
    private let close: [UInt8] = [0x1B, 0x5B] + Array("201~".utf8)

    @Test func commandModeTypesTheLineAndPressesEnter() {
        let out = ComposeEncoder.encode("ls -la", mode: .command, appendEnter: true, bracketedPaste: true)
        #expect(out == bytes("ls -la\r"))
    }

    @Test func commandModeRunsEachLine() {
        let out = ComposeEncoder.encode("cd /tmp\nls", mode: .command, appendEnter: true, bracketedPaste: false)
        #expect(out == bytes("cd /tmp\rls\r"))
    }

    @Test func textModeIsOneBracketedPasteWhenTheRemoteEnabledIt() {
        let out = ComposeEncoder.encode("line 1\nline 2", mode: .text, appendEnter: false, bracketedPaste: true)
        #expect(out == open + bytes("line 1\rline 2") + close)
    }

    @Test func textModeWithoutBracketedPasteIsPlain() {
        let out = ComposeEncoder.encode("a\nb", mode: .text, appendEnter: true, bracketedPaste: false)
        #expect(out == bytes("a\rb\r"))
    }

    @Test func aDraftCannotBreakOutOfTheBracket() {
        let evil = "x\u{1B}[201~rm -rf ~\u{1B}[200~"
        let out = ComposeEncoder.encode(evil, mode: .text, appendEnter: false, bracketedPaste: true)
        #expect(out == open + bytes("x[201~rm -rf ~[200~") + close)
        #expect(!out.dropFirst(open.count).dropLast(close.count).contains(0x1B))
    }

    @Test func keyTokensArePressedOutsideTheBracket() {
        let out = ComposeEncoder.encode("git sta⇥ ⌃C", mode: .text, appendEnter: false, bracketedPaste: true)
        #expect(out == open + bytes("git sta") + close + [0x09] + open + bytes(" ") + close + [0x03])
    }

    @Test func segmentsSplitAtTokens() {
        #expect(ComposeEncoder.segments(of: "ls⏎pwd") == [.text("ls"), .key(.enter), .text("pwd")])
        #expect(ComposeEncoder.segments(of: "⌃C") == [.key(.interrupt)])
        #expect(ComposeEncoder.segments(of: "") == [])
    }

    @Test func modesDefaultTheEnterToggle() {
        #expect(ComposeMode.command.defaultAppendsEnter)
        #expect(!ComposeMode.text.defaultAppendsEnter)
    }
}

@Suite struct SpokenShortcutsTests {
    @Test func newLineBecomesANewline() {
        #expect(SpokenShortcuts.apply(to: "echo one new line echo two") == "echo one\necho two")
        #expect(SpokenShortcuts.apply(to: "first Newline second") == "first\nsecond")
    }

    @Test func keysBecomeTokens() {
        #expect(SpokenShortcuts.apply(to: "ls -la enter") == "ls -la⏎")
        #expect(SpokenShortcuts.apply(to: "git che tab") == "git che⇥")
        #expect(SpokenShortcuts.apply(to: "control C") == "⌃C")
        #expect(SpokenShortcuts.apply(to: "top Control-C") == "top⌃C")
        #expect(SpokenShortcuts.apply(to: "ctrl c") == "⌃C")
    }

    @Test func punctuationAndCaseAreIgnored() {
        #expect(SpokenShortcuts.apply(to: "uptime. Enter.") == "uptime.⏎")
    }

    @Test func otherWordsStay() {
        #expect(SpokenShortcuts.apply(to: "make tables control center") == "make tables control center")
        #expect(SpokenShortcuts.apply(to: "") == "")
    }

    @Test func theTokensAreWhatTheEncoderPresses() {
        let draft = SpokenShortcuts.apply(to: "make test enter")
        #expect(ComposeEncoder.encode(draft, mode: .command, appendEnter: false, bracketedPaste: false)
            == Array("make test\r".utf8))
    }

    @Test func helpCoversEveryShortcut() {
        #expect(SpokenShortcuts.help.map(\.say) == ["new line", "enter", "tab", "control C"])
    }
}
