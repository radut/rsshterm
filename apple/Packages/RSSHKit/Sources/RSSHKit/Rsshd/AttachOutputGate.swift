import Foundation

/// Hides what a login shell prints between opening and running the typed `exec rsshd attach` (prompt, the echoed
/// command, a motd): output is held until tmux or screen switch to the alternate screen, which both do first
/// thing on attach. The app opens the gate itself after a timeout, so an error ("rsshd: not found") still shows.
public struct AttachOutputGate: Sendable {
    /// ESC [ ? 1049 h, and the older 47 / 1047 forms some terminfo entries use.
    static let markers: [[UInt8]] = ["\u{1b}[?1049h", "\u{1b}[?1047h", "\u{1b}[?47h"].map { Array($0.utf8) }

    private var held: [UInt8] = []
    private let limit: Int
    public private(set) var isOpen = false

    public init(limit: Int = 256 * 1024) { self.limit = limit }

    /// What may reach the terminal now.
    public mutating func feed(_ bytes: [UInt8]) -> [UInt8] {
        if isOpen { return bytes }
        held += bytes
        if let start = Self.markerStart(in: held) {
            isOpen = true
            let passed = Array(held[start...])
            held = []
            return passed
        }
        return held.count > limit ? open() : []
    }

    /// Opens the gate and returns everything held.
    public mutating func open() -> [UInt8] {
        isOpen = true
        defer { held = [] }
        return held
    }

    private static func markerStart(in bytes: [UInt8]) -> Int? {
        markers.compactMap { marker in
            bytes.indices.first { i in
                i + marker.count <= bytes.count && bytes[i..<(i + marker.count)].elementsEqual(marker)
            }
        }.min()
    }
}
