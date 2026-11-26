import Foundation

/// The look of a pane that receives broadcast input, shared by the macOS and Linux apps: a red-orange diagonal hatch
/// over the whole pane (behind the badge, through the text, like iTerm2's broadcast background), plus a thin border.
/// Lengths are in points (macOS) or CSS pixels (GTK), measured across the stripes.
public struct BroadcastPattern: Equatable, Sendable {
    /// The stripe colour (0...1 sRGB).
    public let red: Double, green: Double, blue: Double
    /// Width of one stripe, across the stripe.
    public let stripeWidth: Double
    /// Stripe plus gap, across the stripes.
    public let period: Double
    /// Stripes run bottom-left to top-right ("/") at this angle from the horizontal.
    public let angleDegrees: Double
    /// Stripe opacity on a dark terminal background and on a light one (a light background needs less to show).
    public let darkOpacity: Double, lightOpacity: Double
    /// The border around the pane.
    public let borderWidth: Double, borderOpacity: Double

    public static let standard = BroadcastPattern(
        red: 0.89, green: 0.25, blue: 0.13, stripeWidth: 10, period: 20, angleDegrees: 45,
        darkOpacity: 0.25, lightOpacity: 0.16, borderWidth: 2, borderOpacity: 0.85)

    public init(red: Double, green: Double, blue: Double, stripeWidth: Double, period: Double, angleDegrees: Double,
                darkOpacity: Double, lightOpacity: Double, borderWidth: Double, borderOpacity: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.stripeWidth = stripeWidth
        self.period = period
        self.angleDegrees = angleDegrees
        self.darkOpacity = darkOpacity
        self.lightOpacity = lightOpacity
        self.borderWidth = borderWidth
        self.borderOpacity = borderOpacity
    }

    /// Stripe opacity for a terminal background.
    public func opacity(darkBackground: Bool) -> Double { darkBackground ? darkOpacity : lightOpacity }

    /// Horizontal distance between two stripes (where they cross a horizontal line).
    public var horizontalStep: Double { period / sin(angleDegrees * .pi / 180) }

    /// "rgba(r,g,b,a)" for GTK CSS, 0...255 channels.
    public func cssColor(opacity: Double) -> String {
        func c(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return "rgba(\(c(red)),\(c(green)),\(c(blue)),\(Self.format(opacity)))"
    }

    /// The GTK CSS rule painting the hatch and border on `selector` for a dark or light terminal background.
    /// CSS gradient angles point along the gradient line, so "/" stripes at `angleDegrees` take 90 + angleDegrees.
    public func css(selector: String, darkBackground: Bool) -> String {
        let stripe = cssColor(opacity: opacity(darkBackground: darkBackground))
        let w = Self.format(stripeWidth), p = Self.format(period)
        return "\(selector) { border: \(Self.format(borderWidth))px solid \(cssColor(opacity: borderOpacity)); "
            + "background-image: repeating-linear-gradient(\(Self.format(90 + angleDegrees))deg, "
            + "\(stripe) 0px, \(stripe) \(w)px, transparent \(w)px, transparent \(p)px); }"
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

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
