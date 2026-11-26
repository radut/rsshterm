import Foundation
import Testing
@testable import RSSHDesktopCore

@Suite struct BroadcastPatternTests {
    let p = BroadcastPattern.standard

    @Test func standardIsARedOrangeHatchAtFortyFiveDegrees() {
        #expect(p.red > 0.8 && p.green < 0.4 && p.blue < 0.3)
        #expect(p.angleDegrees == 45)
        #expect(p.stripeWidth == 10 && p.period == 20)
        #expect(p.borderWidth == 2)
    }

    @Test func visibleButReadableOpacityPerBackground() {
        #expect((0.18...0.25).contains(p.opacity(darkBackground: true)))
        #expect((0.12...0.2).contains(p.opacity(darkBackground: false)))
        #expect(p.opacity(darkBackground: false) < p.opacity(darkBackground: true))
    }

    @Test func horizontalStepIsThePeriodAlongAHorizontalLine() {
        #expect(abs(p.horizontalStep - 20 * 2.0.squareRoot()) < 0.001)
    }

    @Test func cssSnapshotDark() {
        #expect(p.css(selector: ".broadcast-hatch", darkBackground: true) ==
            ".broadcast-hatch { border: 2px solid rgba(227,64,33,0.85); background-image: repeating-linear-gradient(135deg, "
            + "rgba(227,64,33,0.25) 0px, rgba(227,64,33,0.25) 10px, transparent 10px, transparent 20px); }")
    }

    @Test func cssSnapshotLight() {
        #expect(p.css(selector: ".x", darkBackground: false).contains("rgba(227,64,33,0.16) 10px"))
    }

    @Test func darkBackgroundsByLuminance() {
        #expect(BroadcastPattern.isDark(hex: "#000000"))
        #expect(BroadcastPattern.isDark(hex: "#1e1f22"))
        #expect(BroadcastPattern.isDark(hex: "#2e3440"))
        #expect(!BroadcastPattern.isDark(hex: "#fbfbfb"))
        #expect(!BroadcastPattern.isDark(hex: "#fdf6e3"))
        #expect(!BroadcastPattern.isDark(hex: "#fff"))
        #expect(BroadcastPattern.isDark(hex: "nonsense"))
    }
}
