import Testing
@testable import RSSHTermLinux

@Suite struct PastePolicyTests {
    @Test func plainTextNeedsNoConfirmation() {
        #expect(!PastePolicy.needsConfirmation("ls -la"))
        #expect(!PastePolicy.needsConfirmation("a\tb"))
        #expect(!PastePolicy.needsConfirmation(""))
    }

    @Test(arguments: ["a\nb", "rm -rf x\r", "x\r\n", "a\u{85}b", "a\u{2028}b", "a\u{2029}b", "\u{1b}[201~ls\r", "a\u{4}", "a\u{7f}"])
    func lineEndsAndControlsAsk(_ text: String) {
        #expect(PastePolicy.needsConfirmation(text))
    }
}
