import Foundation

/// The look of a pane in the broadcast, shared by the macOS and Linux apps, after iTerm2: wide diagonal bands ("/",
/// 45 degrees) of deep red with equal gaps, about 2.75 text lines across, over the whole pane, no outline.
///
/// The bands are one sheet behind the whole window: each pane draws the part its frame shows, so they run on across
/// the dividers. Lengths are points (macOS) or pixels (GTK); positions are window coordinates.
public struct BroadcastPattern: Equatable, Sendable {
    /// A colour painted at `opacity` over the terminal (0...1 sRGB).
    public struct Tone: Equatable, Sendable {
        public let red: Double, green: Double, blue: Double, opacity: Double

        public init(red: Double, green: Double, blue: Double, opacity: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.opacity = opacity
        }

        /// The colour it shows over an opaque background.
        public func over(red r: Double, green g: Double, blue b: Double) -> (red: Double, green: Double, blue: Double) {
            (red * opacity + r * (1 - opacity), green * opacity + g * (1 - opacity), blue * opacity + b * (1 - opacity))
        }
    }

    /// A band's centre line in the pane's own coordinates (it runs past the pane: the caller clips to the pane).
    public struct Segment: Equatable, Sendable {
        public let x0: Double, y0: Double, x1: Double, y1: Double
    }

    /// Band width across the band, in text lines.
    public let bandLines: Double
    /// Narrowest band, whatever the font.
    public let minimumBand: Double
    /// Bands run bottom-left to top-right ("/") at this angle from the horizontal.
    public let angleDegrees: Double
    /// Over a dark terminal background, and over a light one.
    public let dark: Tone, light: Tone

    /// Over black: about #661414 (deep red, white text stays readable). Over white: about #FFE5E5.
    public static let standard = BroadcastPattern(
        bandLines: 2.75, minimumBand: 8, angleDegrees: 45,
        dark: Tone(red: 1, green: 0.2, blue: 0.2, opacity: 0.4),
        light: Tone(red: 1, green: 0.2, blue: 0.2, opacity: 0.13))

    public init(bandLines: Double, minimumBand: Double, angleDegrees: Double, dark: Tone, light: Tone) {
        self.bandLines = bandLines
        self.minimumBand = minimumBand
        self.angleDegrees = angleDegrees
        self.dark = dark
        self.light = light
    }

    public func tone(darkBackground: Bool) -> Tone { darkBackground ? dark : light }

    /// Width of one band for a terminal font whose line is `lineHeight` tall.
    public func stripeWidth(lineHeight: Double) -> Double { max(minimumBand, bandLines * lineHeight) }

    /// Band plus gap (the gap is as wide as the band).
    public func period(lineHeight: Double) -> Double { 2 * stripeWidth(lineHeight: lineHeight) }

    /// The bands' centre lines over a pane whose frame starts at `origin` (window coordinates) and is `width` by
    /// `height`, in the pane's own coordinates. `yUp`: y grows upwards (AppKit); else downwards (GTK). Stroke each
    /// with `stripeWidth(lineHeight:)` and clip to the pane.
    public func stripes(origin: (x: Double, y: Double), width: Double, height: Double, lineHeight: Double,
                        yUp: Bool) -> [Segment] {
        guard width > 0, height > 0 else { return [] }
        let angle = angleDegrees * .pi / 180, s = sin(angle), c = cos(angle)
        let band = stripeWidth(lineHeight: lineHeight), period = 2 * band
        // u: position across the bands, window coordinates. Lines of constant u run "/" in either y direction.
        func u(_ x: Double, _ y: Double) -> Double { yUp ? x * s - y * c : x * s + y * c }
        let corners = [(0.0, 0.0), (width, 0), (0, height), (width, height)].map { u($0.0 + origin.x, $0.1 + origin.y) }
        let low = corners.min()!, high = corners.max()!
        let reach = band // run the lines past the edges so the stroke covers the corners
        let y0 = -reach, y1 = height + reach
        var out: [Segment] = []
        var k = ((low - band / 2) / period).rounded(.down) - 1
        while k * period + band / 2 <= high + period {
            let line = k * period + band / 2 - u(origin.x, origin.y) // the centre line in pane coordinates
            func x(_ y: Double) -> Double { yUp ? (line + y * c) / s : (line - y * c) / s }
            out.append(Segment(x0: x(y0), y0: y0, x1: x(y1), y1: y1))
            k += 1
        }
        return out
    }

    /// Whether a "#rrggbb" (or "#rgb") background is dark: WCAG relative luminance under 0.4. Unparseable: dark
    /// (the black default theme).
    public static func isDark(hex: String) -> Bool {
        guard let (r, g, b) = rgb(hex: hex) else { return true }
        return luminance(red: r, green: g, blue: b) < 0.4
    }

    /// WCAG relative luminance of a 0...1 sRGB colour.
    public static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    static func rgb(hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
    }
}
