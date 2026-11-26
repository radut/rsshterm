import Foundation

/// One tab: a split tree, the focused pane and, while zoomed, the pane shown alone. Every edit returns a new value.
/// Invariant: `focused` (and `zoomed`, when set) is a pane of `root`.
public struct Tab: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// A title the user set; nil shows the focused pane's own title.
    public let title: String?
    public let root: SplitNode
    public let focused: PaneID
    public let zoomed: PaneID?

    public init(id: UUID = UUID(), title: String? = nil, pane: Pane) {
        self.init(id: id, title: title, root: .pane(pane), focused: pane.id, zoomed: nil)
    }

    private init(id: UUID, title: String?, root: SplitNode, focused: PaneID, zoomed: PaneID?) {
        self.id = id
        self.title = title
        self.root = root
        self.focused = focused
        self.zoomed = zoomed
    }

    private func with(root: SplitNode? = nil, focused: PaneID? = nil, zoomed: PaneID?? = .none,
                      title: String?? = .none) -> Tab {
        Tab(id: id, title: title ?? self.title, root: root ?? self.root, focused: focused ?? self.focused,
            zoomed: zoomed ?? self.zoomed)
    }

    /// The same tab over another tree (focus, zoom and title kept): for edits in other files.
    func replacingRoot(_ newRoot: SplitNode) -> Tab { with(root: newRoot) }

    public var paneIDs: [PaneID] { root.panes.map(\.id) }
    public var panes: [Pane] { root.panes }
    public var focusedPane: Pane { root.panes.first { $0.id == focused }! }

    /// The rectangles to draw: only the zoomed pane while zoomed, else every pane.
    public var visibleFrames: [PaneID: UnitRect] {
        if let zoomed { return [zoomed: .full] }
        return root.frames()
    }

    public func renamed(_ title: String?) -> Tab { with(title: .some(title)) }

    /// The same tab with each pane's content from `transform`: what session restore saves (a shell's working
    /// directory). Ids, splits, focus, zoom and title are kept.
    public func replacingContents(_ transform: (Pane) -> PaneContent) -> Tab {
        with(root: root.replacingContents(transform))
    }

    /// Splits the focused pane; the new pane takes focus and zoom ends.
    public func splitting(_ direction: Direction, with pane: Pane) -> Tab {
        with(root: root.splitting(focused, direction, with: pane), focused: pane.id, zoomed: .some(nil))
    }

    /// Focus on `id`, when it is a pane of this tab.
    public func focusing(_ id: PaneID) -> Tab {
        guard root.contains(id) else { return self }
        return with(focused: id, zoomed: .some(zoomed == nil ? nil : id))
    }

    /// The tab without pane `id`, its split collapsed; focus goes to the pane that took its place. Nil when it was
    /// the tab's last pane (the tab closes).
    public func closing(_ id: PaneID) -> Tab? {
        guard root.contains(id) else { return self }
        guard let newRoot = root.removing(id) else { return nil }
        let newFocus = focused == id ? Self.successor(of: id, in: root, after: newRoot) : focused
        return with(root: newRoot, focused: newFocus, zoomed: .some(zoomed == id ? nil : zoomed))
    }

    /// The first pane of the subtree that was the closed pane's sibling.
    private static func successor(of id: PaneID, in old: SplitNode, after new: SplitNode) -> PaneID {
        func sibling(in node: SplitNode) -> SplitNode? {
            guard case .split(_, _, let first, let second) = node else { return nil }
            if case .pane(let p) = first, p.id == id { return second }
            if case .pane(let p) = second, p.id == id { return first }
            return sibling(in: first.contains(id) ? first : second)
        }
        let candidate = sibling(in: old).map { side in
            // the focused pane of the surviving side: the one nearest the closed pane
            side.panes.first!.id
        }
        return candidate ?? new.panes.first!.id
    }

    /// Focus on the nearest pane in `direction` whose edge touches the focused pane's and overlaps it; ties go to
    /// the top (or left) one. Unchanged when there is none. Leaves zoom.
    public func movingFocus(_ direction: Direction) -> Tab {
        let frames = root.frames()
        guard let from = frames[focused] else { return self }
        let eps = 1e-9
        let candidates: [(PaneID, Double, Double)] = frames.compactMap { id, rect in
            guard id != focused else { return nil }
            switch direction {
            case .left where rect.maxX <= from.x + eps && overlaps(rect.y, rect.maxY, from.y, from.maxY):
                return (id, from.x - rect.maxX, rect.y)
            case .right where rect.x >= from.maxX - eps && overlaps(rect.y, rect.maxY, from.y, from.maxY):
                return (id, rect.x - from.maxX, rect.y)
            case .up where rect.maxY <= from.y + eps && overlaps(rect.x, rect.maxX, from.x, from.maxX):
                return (id, from.y - rect.maxY, rect.x)
            case .down where rect.y >= from.maxY - eps && overlaps(rect.x, rect.maxX, from.x, from.maxX):
                return (id, rect.y - from.maxY, rect.x)
            default:
                return nil
            }
        }
        guard let best = candidates.min(by: { ($0.1, $0.2) < ($1.1, $1.2) }) else { return self }
        return with(focused: best.0, zoomed: .some(nil))
    }

    private func overlaps(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Bool {
        min(a1, b1) - max(a0, b0) > 1e-9
    }

    /// Focus on the next pane in reading order (wrapping), or the previous one. Leaves zoom.
    public func focusingNextPane() -> Tab { cyclingFocus(by: 1) }
    public func focusingPreviousPane() -> Tab { cyclingFocus(by: -1) }

    private func cyclingFocus(by step: Int) -> Tab {
        let ids = paneIDs
        guard ids.count > 1, let index = ids.firstIndex(of: focused) else { return self }
        return with(focused: ids[(index + step + ids.count) % ids.count], zoomed: .some(nil))
    }

    /// The share one resize key press moves a divider.
    public static let resizeStep = 0.05

    /// Moves the focused pane's divider towards `direction` by `resizeStep`.
    public func resizingFocused(_ direction: Direction) -> Tab {
        let delta = direction == .left || direction == .up ? -Self.resizeStep : Self.resizeStep
        return resizing(focused, axis: direction.axis, by: delta)
    }

    /// Every pane of a row or column the same size.
    public func equalized() -> Tab { with(root: root.equalized()) }

    /// Moves the nearest `axis` divider around pane `id` by `delta` (a share of that split, negative = towards the
    /// left/top). Unchanged when no split on that axis holds the pane.
    public func resizing(_ id: PaneID, axis: SplitAxis, by delta: Double) -> Tab {
        guard let newRoot = root.resizing(id, axis: axis, by: delta) else { return self }
        return with(root: newRoot)
    }

    /// Shows the focused pane alone, or ends the zoom. A tab with one pane has nothing to zoom.
    public func togglingZoom() -> Tab {
        if zoomed != nil { return with(zoomed: .some(nil)) }
        guard root.panes.count > 1 else { return self }
        return with(zoomed: .some(focused))
    }
}

extension Tab {
    private enum CodingKeys: String, CodingKey { case id, title, root, focused, zoomed }

    /// A saved session from a damaged or older file must not crash the app: focus outside the tree is an error,
    /// a stale zoom is dropped.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let root = try c.decode(SplitNode.self, forKey: .root)
        let focused = try c.decode(PaneID.self, forKey: .focused)
        guard root.contains(focused) else {
            throw DecodingError.dataCorruptedError(forKey: .focused, in: c, debugDescription: "focused pane not in tab")
        }
        let zoomed = try c.decodeIfPresent(PaneID.self, forKey: .zoomed).flatMap { root.contains($0) ? $0 : nil }
        self.init(id: try c.decode(UUID.self, forKey: .id), title: try c.decodeIfPresent(String.self, forKey: .title),
                  root: root, focused: focused, zoomed: zoomed)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(root, forKey: .root)
        try c.encode(focused, forKey: .focused)
        try c.encodeIfPresent(zoomed, forKey: .zoomed)
    }
}
