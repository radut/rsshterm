import Foundation
import Testing
@testable import RSSHDesktopCore

@Suite struct BroadcastPatternTests {
    let p = BroadcastPattern.standard

    /// iTerm2's look: wide "/" bands at 45 degrees, about 2.75 text lines across, equal gaps, no outline.
    @Test func wideBandsThatFollowTheFont() {
        #expect(p.angleDegrees == 45)
        #expect(abs(p.stripeWidth(lineHeight: 16) - 44) < 0.001)
        #expect(abs(p.period(lineHeight: 16) - 88) < 0.001) // band and gap the same width
        #expect(p.stripeWidth(lineHeight: 20) > p.stripeWidth(lineHeight: 16))
        #expect(p.stripeWidth(lineHeight: 0) >= 8) // a lineless pane still gets visible bands
    }

    /// Over black the dark tone comes out deep red (about #5C1212 to #6B1515); over white the light tone is a pale
    /// red that keeps text readable.
    @Test func deepRedOnDarkPaleRedOnLight() {
        let dark = p.tone(darkBackground: true).over(red: 0, green: 0, blue: 0)
        #expect((0x5c...0x6b).contains(Int((dark.red * 255).rounded())))
        #expect((0x10...0x16).contains(Int((dark.green * 255).rounded())))
        #expect((0x10...0x16).contains(Int((dark.blue * 255).rounded())))
        let light = p.tone(darkBackground: false).over(red: 1, green: 1, blue: 1)
        #expect(light.red > 0.98 && (0.82...0.93).contains(light.green) && (0.82...0.93).contains(light.blue))
        #expect(BroadcastPattern.luminance(red: light.red, green: light.green, blue: light.blue) > 0.6)
    }

    /// The centre line of each band, window coordinates: across-the-stripes position u, modulo the period, is half
    /// a band. Both panes of a split agree, so the bands run on across the divider.
    func phases(_ segments: [BroadcastPattern.Segment], origin: (Double, Double), yUp: Bool, period: Double) -> [Double] {
        let s = sin(p.angleDegrees * .pi / 180), c = cos(p.angleDegrees * .pi / 180)
        return segments.flatMap { seg in [seg.x0, seg.x1].indices.map { i -> Double in
            let x = (i == 0 ? seg.x0 : seg.x1) + origin.0, y = (i == 0 ? seg.y0 : seg.y1) + origin.1
            let u = yUp ? x * s - y * c : x * s + y * c
            return (u.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period)
        } }
    }

    @Test(arguments: [true, false]) func bandsLineUpAcrossDividers(yUp: Bool) {
        let line = 17.0, width = p.stripeWidth(lineHeight: line), period = p.period(lineHeight: line)
        // 2x2: left/right at x 0 and 401, top/bottom at y 0 and 301 (1-point dividers).
        for origin in [(0.0, 0.0), (401.0, 0.0), (0.0, 301.0), (401.0, 301.0)] {
            let segs = p.stripes(origin: origin, width: 400, height: 300, lineHeight: line, yUp: yUp)
            #expect(!segs.isEmpty)
            for phase in phases(segs, origin: origin, yUp: yUp, period: period) {
                #expect(abs(phase - width / 2) < 0.001 || abs(phase - width / 2 - period) < 0.001)
            }
        }
    }

    /// The bands cover the whole pane: every point lies within half a period of a centre line.
    @Test(arguments: [true, false]) func bandsCoverThePane(yUp: Bool) {
        let line = 15.0, period = p.period(lineHeight: line)
        let origin = (123.0, 45.0), w = 900.0, h = 120.0 // wide and short: the old drawing missed corners
        let segs = p.stripes(origin: origin, width: w, height: h, lineHeight: line, yUp: yUp)
        let s = sin(p.angleDegrees * .pi / 180), c = cos(p.angleDegrees * .pi / 180)
        func u(_ x: Double, _ y: Double) -> Double { yUp ? x * s - y * c : x * s + y * c }
        let lines = segs.map { u($0.x0, $0.y0) }
        for (x, y) in [(0.0, 0.0), (w, 0), (0, h), (w, h), (w / 2, h / 2)] {
            #expect(lines.contains { abs(u(x, y) - $0) <= period / 2 + 0.001 })
        }
        // Each segment runs past the top and bottom edges, so the clip trims it, never the end of a line.
        for seg in segs {
            #expect(min(seg.y0, seg.y1) < 0 && max(seg.y0, seg.y1) > h)
        }
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
