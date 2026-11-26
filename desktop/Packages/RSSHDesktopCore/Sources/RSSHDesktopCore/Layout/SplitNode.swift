import Foundation

/// The split tree of one tab: a pane, or a split of two subtrees along an axis. `ratio` is the share of the first
/// child. Value type: every edit returns a new tree.
public indirect enum SplitNode: Codable, Hashable, Sendable {
    case pane(Pane)
    case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)

    /// No child gets less than this share of its split, so a pane never shrinks to nothing.
    public static let minimumRatio = 0.1

    /// The panes left to right, top to bottom (depth first).
    public var panes: [Pane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }

    public func contains(_ id: PaneID) -> Bool { panes.contains { $0.id == id } }

    /// Each pane's rectangle in `rect`.
    public func frames(in rect: UnitRect = .full) -> [PaneID: UnitRect] {
        switch self {
        case .pane(let pane):
            return [pane.id: rect]
        case .split(let axis, let ratio, let first, let second):
            let (a, b) = Self.divide(rect, axis: axis, ratio: ratio)
            return first.frames(in: a).merging(second.frames(in: b)) { lhs, _ in lhs }
        }
    }

    static func divide(_ rect: UnitRect, axis: SplitAxis, ratio: Double) -> (UnitRect, UnitRect) {
        switch axis {
        case .horizontal:
            let w = rect.width * ratio
            return (UnitRect(x: rect.x, y: rect.y, width: w, height: rect.height),
                    UnitRect(x: rect.x + w, y: rect.y, width: rect.width - w, height: rect.height))
        case .vertical:
            let h = rect.height * ratio
            return (UnitRect(x: rect.x, y: rect.y, width: rect.width, height: h),
                    UnitRect(x: rect.x, y: rect.y + h, width: rect.width, height: rect.height - h))
        }
    }

    /// The tree with pane `target` replaced by a split of it and `new`, the new pane on the `direction` side.
    func splitting(_ target: PaneID, _ direction: Direction, with new: Pane) -> SplitNode {
        switch self {
        case .pane(let pane) where pane.id == target:
            let (first, second): (SplitNode, SplitNode) = direction.placesAfter ? (self, .pane(new)) : (.pane(new), self)
            return .split(axis: direction.axis, ratio: 0.5, first: first, second: second)
        case .pane:
            return self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.splitting(target, direction, with: new),
                          second: second.splitting(target, direction, with: new))
        }
    }

    /// The tree without pane `target`: its split collapses into the sibling. Nil when `target` was the only pane.
    func removing(_ target: PaneID) -> SplitNode? {
        switch self {
        case .pane(let pane):
            return pane.id == target ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard let newFirst = first.removing(target) else { return second }
            guard let newSecond = second.removing(target) else { return first }
            return .split(axis: axis, ratio: ratio, first: newFirst, second: newSecond)
        }
    }

    /// The same tree with each pane's content from `transform` (ids, axes and ratios kept).
    func replacingContents(_ transform: (Pane) -> PaneContent) -> SplitNode {
        switch self {
        case .pane(let pane):
            return .pane(Pane(id: pane.id, content: transform(pane)))
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.replacingContents(transform),
                          second: second.replacingContents(transform))
        }
    }

    /// Every split's ratio set so panes in a run of same-axis splits share the space equally.
    func equalized() -> SplitNode {
        switch self {
        case .pane:
            return self
        case .split(let axis, _, let first, let second):
            let (a, b) = (first.slots(along: axis), second.slots(along: axis))
            return .split(axis: axis, ratio: Double(a) / Double(a + b), first: first.equalized(),
                          second: second.equalized())
        }
    }

    /// How many panes this subtree lines up along `axis`.
    private func slots(along axis: SplitAxis) -> Int {
        switch self {
        case .split(let own, _, let first, let second) where own == axis:
            first.slots(along: axis) + second.slots(along: axis)
        default:
            1
        }
    }

    /// Moves the divider of the innermost `axis` split that holds `target`, by `delta` of that split's size; the
    /// result is clamped to [minimumRatio, 1 - minimumRatio]. Nil when no such split holds the pane.
    func resizing(_ target: PaneID, axis: SplitAxis, by delta: Double) -> SplitNode? {
        guard case .split(let own, let ratio, let first, let second) = self else { return nil }
        if let inner = first.resizing(target, axis: axis, by: delta) {
            return .split(axis: own, ratio: ratio, first: inner, second: second)
        }
        if let inner = second.resizing(target, axis: axis, by: delta) {
            return .split(axis: own, ratio: ratio, first: first, second: inner)
        }
        guard own == axis, contains(target) else { return nil }
        let clamped = min(max(ratio + delta, Self.minimumRatio), 1 - Self.minimumRatio)
        return .split(axis: own, ratio: clamped, first: first, second: second)
    }
}

extension SplitNode {
    private enum CodingKeys: String, CodingKey { case pane, axis, ratio, first, second }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try c.decodeIfPresent(Pane.self, forKey: .pane) {
            self = .pane(pane)
            return
        }
        let ratio = try c.decode(Double.self, forKey: .ratio)
        guard ratio.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .ratio, in: c, debugDescription: "ratio is not finite")
        }
        self = .split(axis: try c.decode(SplitAxis.self, forKey: .axis),
                      ratio: min(max(ratio, Self.minimumRatio), 1 - Self.minimumRatio),
                      first: try c.decode(SplitNode.self, forKey: .first),
                      second: try c.decode(SplitNode.self, forKey: .second))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try c.encode(pane, forKey: .pane)
        case .split(let axis, let ratio, let first, let second):
            try c.encode(axis, forKey: .axis)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }
}
