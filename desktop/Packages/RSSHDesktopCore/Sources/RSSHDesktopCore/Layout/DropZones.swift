import Foundation

/// Where on a pane a dragged pane lands: along one of its edges (it takes that half) or its centre (the two swap).
public enum DropZone: Equatable, Hashable, Sendable {
    case edge(Direction)
    case center
}

/// Where a pane or tab dragged over a tab's panes lands: the pane under the pointer and its zone (iTerm2: the half
/// nearest the pointer, or the centre to swap), and the rectangle the highlight covers. Unit square coordinates,
/// like `Tab.visibleFrames`.
public enum DropZones {
    public struct Target: Equatable, Sendable {
        public let pane: PaneID
        public let zone: DropZone
        /// The edge nearest the pointer, also in the centre (where a tab, which never swaps, goes).
        public let edge: Direction
        /// The rectangle the highlight covers: the `zone` half of the target pane, or all of it for the centre.
        public let preview: UnitRect

        public init(pane: PaneID, zone: DropZone, edge: Direction? = nil, preview: UnitRect) {
            self.pane = pane
            self.zone = zone
            if case .edge(let e) = zone { self.edge = e } else { self.edge = edge ?? .right }
            self.preview = preview
        }
    }

    /// The centre box (swap) is the middle `centerSize` of the pane on each axis.
    public static let centerSize = 0.4

    /// The zone of `rect` at (x, y); nil outside it. Without `center` (a tab dragged onto a pane) the nearest edge
    /// always wins. Ties go to left/right (the common split).
    public static func zone(x: Double, y: Double, in rect: UnitRect, center: Bool = true) -> DropZone? {
        guard let edge = nearestEdge(x: x, y: y, in: rect) else { return nil }
        let rx = (x - rect.x) / rect.width, ry = (y - rect.y) / rect.height
        let low = (1 - centerSize) / 2, high = 1 - low
        if center, rx >= low, rx <= high, ry >= low, ry <= high { return .center }
        return .edge(edge)
    }

    private static func nearestEdge(x: Double, y: Double, in rect: UnitRect) -> Direction? {
        guard rect.width > 0, rect.height > 0, x >= rect.x, x <= rect.maxX, y >= rect.y, y <= rect.maxY else {
            return nil
        }
        let rx = (x - rect.x) / rect.width, ry = (y - rect.y) / rect.height
        let distances: [(Direction, Double)] = [(.left, rx), (.right, 1 - rx), (.up, ry), (.down, 1 - ry)]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// The target at (x, y) among `frames`; nil outside every pane. The centre (swap) is offered only when asked
    /// for (a dragged pane); otherwise the nearest edge, as before the centre existed.
    public static func target(x: Double, y: Double, frames: [PaneID: UnitRect], center: Bool = false) -> Target? {
        for (pane, rect) in frames {
            if let zone = zone(x: x, y: y, in: rect, center: center), let edge = nearestEdge(x: x, y: y, in: rect) {
                return Target(pane: pane, zone: zone, edge: edge, preview: highlight(zone, in: rect))
            }
        }
        return nil
    }

    /// What the highlight covers for `zone` of `rect`.
    public static func highlight(_ zone: DropZone, in rect: UnitRect) -> UnitRect {
        switch zone {
        case .edge(let edge): half(of: rect, edge)
        case .center: rect
        }
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

/// Where a tab (or a pane, as a new tab) dropped on a tab bar goes: the insertion slot under the pointer, the
/// marker between tabs, and how far the neighbours slide to open the gap. Points along the bar, any unit.
public enum TabInsertion {
    public struct Span: Equatable, Sendable {
        public let x: Double
        public let width: Double
        public init(x: Double, width: Double) {
            self.x = x
            self.width = width
        }
        public var maxX: Double { x + width }
    }

    /// The slot (0...count) at `x`: before the first tab whose middle is right of the pointer.
    public static func slot(x: Double, frames: [Span]) -> Int {
        frames.firstIndex { x < $0.x + $0.width / 2 } ?? frames.count
    }

    /// The tab's index after the drop of tab `dragged` (its index in this bar, nil when it comes from elsewhere) at
    /// `slot`; nil when that is where it already is.
    public static func destination(slot: Int, dragged: Int?) -> Int? {
        guard let dragged else { return slot }
        if slot == dragged || slot == dragged + 1 { return nil }
        return slot > dragged ? slot - 1 : slot
    }

    /// How far each tab slides while a tab hovers at `slot`: its own tab (`dragged`) leaves its place, the others
    /// close up and open a `gap`-wide hole at the slot. All zero when the drop would change nothing.
    public static func offsets(widths: [Double], spacing: Double, dragged: Int?, slot: Int?, gap: Double) -> [Double] {
        let none = Array(repeating: 0.0, count: widths.count)
        guard let slot, destination(slot: slot, dragged: dragged) != nil else { return none }
        var natural: [Double] = []
        var x = 0.0
        for w in widths {
            natural.append(x)
            x += w + spacing
        }
        var result = none
        x = 0
        for i in widths.indices where i != dragged {
            if i == slot { x += gap + spacing }
            result[i] = x - natural[i]
            x += widths[i] + spacing
        }
        if let dragged { result[dragged] = 0 }
        return result
    }

    /// Where the gap opened by `offsets` starts, from the first tab's left edge; nil when there is no gap.
    public static func gapX(widths: [Double], spacing: Double, dragged: Int?, slot: Int?) -> Double? {
        guard let slot, destination(slot: slot, dragged: dragged) != nil else { return nil }
        var x = 0.0
        for i in widths.indices where i != dragged {
            if i == slot { return x }
            x += widths[i] + spacing
        }
        return x
    }

    /// Where the insertion marker stands for `slot`: midway between two tabs, or at the bar's ends.
    public static func markerX(slot: Int, frames: [Span]) -> Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if slot <= 0 { return first.x }
        if slot >= frames.count { return last.maxX }
        return (frames[slot - 1].maxX + frames[slot].x) / 2
    }
}
