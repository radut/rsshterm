import Foundation

/// One divider of a tab's split tree, for dragging it with the mouse.
public struct SplitDivider: Equatable, Sendable {
    /// Where its split sits in the tree: 0 = first child, 1 = second, from the root (`[]` is the root split).
    public let path: [Int]
    /// The split's axis: `.horizontal` = side by side, so the divider is a vertical line at x = `position`.
    public let axis: SplitAxis
    /// The divider's x (horizontal axis) or y (vertical axis) in the tab's unit square.
    public let position: Double
    /// The whole split's rectangle: the divider runs across it and moves within it.
    public let span: UnitRect

    /// The divider within `tolerance` of the point (unit square), the innermost first.
    public static func hit(x: Double, y: Double, in dividers: [SplitDivider], tolerance: Double) -> SplitDivider? {
        dividers.sorted { $0.path.count > $1.path.count }.first { d in
            switch d.axis {
            case .horizontal:
                abs(x - d.position) <= tolerance && y >= d.span.y && y <= d.span.maxY
            case .vertical:
                abs(y - d.position) <= tolerance && x >= d.span.x && x <= d.span.maxX
            }
        }
    }
}

extension SplitNode {
    func dividers(in rect: UnitRect, path: [Int]) -> [SplitDivider] {
        guard case .split(let axis, let ratio, let first, let second) = self else { return [] }
        let (a, b) = Self.divide(rect, axis: axis, ratio: ratio)
        let position = axis == .horizontal ? a.maxX : a.maxY
        return [SplitDivider(path: path, axis: axis, position: position, span: rect)]
            + first.dividers(in: a, path: path + [0]) + second.dividers(in: b, path: path + [1])
    }

    /// The tree with the split at `path` set to `ratio` (clamped); nil when `path` is not a split.
    func settingRatio(at path: [Int], to ratio: Double) -> SplitNode? {
        guard case .split(let axis, let current, let first, let second) = self else { return nil }
        guard let step = path.first else {
            let clamped = min(max(ratio, Self.minimumRatio), 1 - Self.minimumRatio)
            return clamped == current ? self : .split(axis: axis, ratio: clamped, first: first, second: second)
        }
        let rest = Array(path.dropFirst())
        if step == 0, let inner = first.settingRatio(at: rest, to: ratio) {
            return .split(axis: axis, ratio: current, first: inner, second: second)
        }
        if step == 1, let inner = second.settingRatio(at: rest, to: ratio) {
            return .split(axis: axis, ratio: current, first: first, second: inner)
        }
        return nil
    }
}

extension Tab {
    /// Every divider of the tree; none while a pane is zoomed (only that pane is shown).
    public var dividers: [SplitDivider] {
        zoomed == nil ? root.dividers(in: .full, path: []) : []
    }

    /// The tab with the divider at `path` moved to `position` (x or y in the unit square); unchanged for a path
    /// that is not a split.
    public func movingDivider(_ path: [Int], to position: Double) -> Tab {
        guard let divider = dividers.first(where: { $0.path == path }) else { return self }
        let ratio = divider.axis == .horizontal
            ? (position - divider.span.x) / divider.span.width
            : (position - divider.span.y) / divider.span.height
        guard let newRoot = root.settingRatio(at: path, to: ratio) else { return self }
        return replacingRoot(newRoot)
    }
}

extension SplitNode {
    func mappingPanes(_ transform: (Pane) -> Pane) -> SplitNode {
        switch self {
        case .pane(let pane): .pane(transform(pane))
        case .split(let axis, let ratio, let first, let second):
            .split(axis: axis, ratio: ratio, first: first.mappingPanes(transform), second: second.mappingPanes(transform))
        }
    }
}

extension Tab {
    /// The same tab with each pane replaced by `transform(pane)` (keep the id): e.g. a shell's current directory
    /// written into its content before the session is saved.
    public func mappingPanes(_ transform: (Pane) -> Pane) -> Tab {
        replacingRoot(root.mappingPanes(transform))
    }
}
