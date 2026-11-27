import Foundation

/// Where a pane or tab dragged over a tab's panes lands: the pane under the pointer and the edge it is nearest
/// (iTerm2, Ghostty and Orca split that way), and the half of the pane the preview covers. Unit square
/// coordinates, like `Tab.visibleFrames`.
public enum DropZones {
    public struct Target: Equatable, Sendable {
        public let pane: PaneID
        public let edge: Direction
        /// The rectangle the moved pane will take: the `edge` half of the target pane.
        public let preview: UnitRect
    }

    /// The target at (x, y) among `frames`; nil outside every pane.
    public static func target(x: Double, y: Double, frames: [PaneID: UnitRect]) -> Target? {
        let hit = frames.first { _, r in x >= r.x && x <= r.maxX && y >= r.y && y <= r.maxY }
        guard let (pane, rect) = hit, rect.width > 0, rect.height > 0 else { return nil }
        let rx = (x - rect.x) / rect.width, ry = (y - rect.y) / rect.height
        // The nearest edge; ties go to left/right (the common split).
        let distances: [(Direction, Double)] = [(.left, rx), (.right, 1 - rx), (.up, ry), (.down, 1 - ry)]
        let edge = distances.min { $0.1 < $1.1 }!.0
        return Target(pane: pane, edge: edge, preview: half(of: rect, edge))
    }

    /// The `edge` half of `rect`.
    public static func half(of rect: UnitRect, _ edge: Direction) -> UnitRect {
        switch edge {
        case .left: UnitRect(x: rect.x, y: rect.y, width: rect.width / 2, height: rect.height)
        case .right: UnitRect(x: rect.midX, y: rect.y, width: rect.width / 2, height: rect.height)
        case .up: UnitRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height / 2)
        case .down: UnitRect(x: rect.x, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }
}
