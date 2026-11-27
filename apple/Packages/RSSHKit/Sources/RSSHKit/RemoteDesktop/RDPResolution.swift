import Foundation

/// A remote desktop size in pixels, as an RDP session asks for it. Even on both sides and within what servers take
/// (the display control channel accepts 200...8192).
public struct RDPDisplaySize: Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let limits = 200...8192
    /// "Match this device" never asks for more than this on its long side (a 13" iPad at 2x would be 2752).
    static let matchLongSideMax: Double = 2560
    /// ... nor less than this on its short side (a remote desktop below 600 lines is hard to use).
    static let matchShortSideMin: Double = 600
    /// The selector's sizes: the screen's points times these, as the Windows App lists them.
    static let choiceFactors: [Double] = [1.25, 1.5, 1.75, 2, 2.25]

    // Plain Double sizes, no CGSize/CGFloat: a Release (-O) build of the app crashed the Swift 6.4.2 compiler
    // deserializing an RSSHKit function that took CoreGraphics types (cross-module optimization). The app's
    // CGSize conveniences live in the app (RDPResolutionPicker.swift).

    public var isLandscape: Bool { width >= height }
    public var rotated: RDPDisplaySize { RDPDisplaySize(width: height, height: width) }
    public var label: String { "\(width) × \(height)" }

    /// This device's screen in landscape (the size asked before the screen rotated with the phone): points ×2 at
    /// most, at least 1024x600, at most 2560x1600.
    public static func forScreen(width: Double, height: Double, scale: Double) -> RDPDisplaySize {
        let long = max(width, height), short = min(width, height)
        let factor = min(max(scale, 1), 2)
        func even(_ v: Double, _ low: Int, _ high: Int) -> Int { min(max(Int(v * factor) & ~1, low), high) }
        return RDPDisplaySize(width: even(long, 1024, 2560), height: even(short, 600, 1600))
    }

    /// "Match this device": the screen as it is held now (portrait stays portrait), in points ×2 at most (a phone's
    /// full pixel count would make the remote UI unreadably small), with the screen's aspect ratio.
    public static func matching(width: Double, height: Double, scale: Double) -> RDPDisplaySize {
        guard width > 0, height > 0 else { return RDPDisplaySize(width: 1280, height: 800) }
        let factor = min(max(scale, 1), 2)
        var w = width * factor, h = height * factor
        let long = max(w, h)
        if long > matchLongSideMax {
            w *= matchLongSideMax / long
            h *= matchLongSideMax / long
        }
        let short = min(w, h)
        if short < matchShortSideMin {
            w *= matchShortSideMin / short
            h *= matchShortSideMin / short
        }
        return RDPDisplaySize(width: even(w), height: even(h))
    }

    /// The sizes the selector offers for the screen as it is held now, smallest first, all with its aspect ratio.
    public static func choices(width: Double, height: Double, scale: Double) -> [RDPDisplaySize] {
        guard width > 0, height > 0 else { return [] }
        let long = max(width, height), short = min(width, height)
        let landscape = width >= height
        var seen = Set<RDPDisplaySize>()
        return choiceFactors.compactMap { factor in
            let longSide = even(long * factor)
            let shortSide = even(Double(longSide) * short / long)
            guard limits.contains(longSide), limits.contains(shortSide) else { return nil }
            let size = landscape ? RDPDisplaySize(width: longSide, height: shortSide)
                                 : RDPDisplaySize(width: shortSide, height: longSide)
            return seen.insert(size).inserted ? size : nil
        }
    }

    /// A size typed by hand, made even; nil outside 200...8192.
    public static func custom(width: Int, height: Int) -> RDPDisplaySize? {
        guard limits.contains(width), limits.contains(height) else { return nil }
        return RDPDisplaySize(width: width & ~1, height: height & ~1)
    }

    /// "1920x1080" or "1920 × 1080".
    public static func parse(_ text: String) -> RDPDisplaySize? {
        let parts = text.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return custom(width: w, height: h)
    }

    private static func even(_ v: Double) -> Int { Int(v.rounded(.down)) & ~1 }
}

/// The desktop size an RDP entry asks for: the device's screen (default), or a fixed size that turns with the phone.
public enum RDPResolution: Hashable, Sendable {
    case matchDevice
    case fixed(RDPDisplaySize)

    /// The size to ask for with the screen held as `width` x `height` points now.
    public func size(width: Double, height: Double, scale: Double) -> RDPDisplaySize {
        switch self {
        case .matchDevice:
            return RDPDisplaySize.matching(width: width, height: height, scale: scale)
        case .fixed(let size):
            let landscape = width >= height
            return size.isLandscape == landscape ? size : size.rotated
        }
    }

    /// Stored as "match" or "<w>x<h>"; anything else reads as `.matchDevice`.
    public var storageValue: String {
        switch self {
        case .matchDevice: "match"
        case .fixed(let size): "\(size.width)x\(size.height)"
        }
    }

    public init(storageValue: String) {
        self = RDPDisplaySize.parse(storageValue).map(RDPResolution.fixed) ?? .matchDevice
    }
}

/// What to do when the size the screen wants (the phone turned, or another resolution was picked) differs from
/// the remote desktop's.
public enum RDPResizeDecision: Equatable, Sendable {
    case keep
    /// The display control channel is open: ask the server to resize the running desktop.
    case resizeLive(RDPDisplaySize)
    /// No display control: connect again at the new size (same login).
    case reconnect(RDPDisplaySize)

    /// Servers may round a requested size; within this many pixels it is the same size.
    static let tolerance = 8

    public static func decide(current: RDPDisplaySize, wanted: RDPDisplaySize, canResizeLive: Bool) -> RDPResizeDecision {
        if abs(current.width - wanted.width) <= tolerance, abs(current.height - wanted.height) <= tolerance {
            return .keep
        }
        return canResizeLive ? .resizeLive(wanted) : .reconnect(wanted)
    }
}
