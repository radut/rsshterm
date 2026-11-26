import Foundation

/// Identifies one terminal pane across splits, moves and session restore.
public struct PaneID: Hashable, Codable, Sendable {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) { self.raw = raw }

    public init(from decoder: any Decoder) throws { raw = try UUID(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
}

/// What runs in a pane. Restoring a session starts these again; it never restores a process.
public enum PaneContent: Codable, Hashable, Sendable {
    /// A local shell, or `command` (argv) when given, started in `directory` (nil: the home directory).
    case localShell(command: [String]? = nil, directory: String? = nil)
    /// An SSH session to a vault server.
    case ssh(serverID: UUID)
    /// A remote desktop of the vault (VNC / Screen Sharing / RDP), drawn instead of a terminal.
    case remoteDesktop(id: UUID)
}

/// One terminal in the split tree.
public struct Pane: Codable, Hashable, Identifiable, Sendable {
    public let id: PaneID
    public let content: PaneContent

    public init(id: PaneID = PaneID(), content: PaneContent) {
        self.id = id
        self.content = content
    }
}

/// Where a new pane goes relative to the focused one, or which way focus moves.
public enum Direction: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    /// The axis a split in this direction divides: left/right make panes side by side.
    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }

    /// True when the new pane comes after the existing one (right of it, or below it).
    var placesAfter: Bool { self == .right || self == .down }
}

/// How a split divides its space: `.horizontal` puts the children side by side (a vertical divider, iTerm2's
/// "split vertically"), `.vertical` stacks them.
public enum SplitAxis: String, Codable, Sendable {
    case horizontal, vertical
}

/// A rectangle in the tab's unit square: x grows rightwards, y downwards.
public struct UnitRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}
