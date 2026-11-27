import Foundation

// Moving panes inside the split tree and between tabs: the pure part of drag and drop, "Move Pane to …",
// "Swap Pane with …" and "Duplicate …". Pane ids never change on a move, so the app keeps each pane's live view
// (shell, ssh, remote desktop) and the hand-picked broadcast set follows the pane.

extension SplitNode {
    /// The pane `id`, when it is in this tree.
    public func pane(_ id: PaneID) -> Pane? { panes.first { $0.id == id } }

    /// The tree with pane `target` replaced by a split of it and `node`, `node` on the `edge` side; the two share
    /// the old pane's space equally. Unchanged when `target` is not in the tree.
    func inserting(_ node: SplitNode, beside target: PaneID, edge: Direction) -> SplitNode {
        switch self {
        case .pane(let pane) where pane.id == target:
            let (first, second) = edge.placesAfter ? (self, node) : (node, self)
            return .split(axis: edge.axis, ratio: 0.5, first: first, second: second)
        case .pane:
            return self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.inserting(node, beside: target, edge: edge),
                          second: second.inserting(node, beside: target, edge: edge))
        }
    }

    /// The whole tree split with `node` on the `edge` side of the tab. A row (or column) of panes on that axis gets
    /// one more slot of the same size, so dropping on the right of three side-by-side panes makes four quarters.
    func inserting(_ node: SplitNode, atEdge edge: Direction) -> SplitNode {
        let existing = Double(slots(along: edge.axis))
        let added = Double(node.slots(along: edge.axis))
        let share = existing / (existing + added)
        let ratio = min(max(edge.placesAfter ? share : 1 - share, Self.minimumRatio), 1 - Self.minimumRatio)
        return edge.placesAfter
            ? .split(axis: edge.axis, ratio: ratio, first: self, second: node)
            : .split(axis: edge.axis, ratio: ratio, first: node, second: self)
    }

    /// Panes `a` and `b` trade places (sizes stay with the places).
    func swapping(_ a: Pane, _ b: Pane) -> SplitNode {
        switch self {
        case .pane(let pane) where pane.id == a.id: return .pane(b)
        case .pane(let pane) where pane.id == b.id: return .pane(a)
        case .pane: return self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.swapping(a, b), second: second.swapping(a, b))
        }
    }

    /// The same shape with new pane ids, each pane's content from `content` (Duplicate Tab). `map` gets old → new.
    func duplicated(_ content: (Pane) -> PaneContent, map: inout [PaneID: PaneID]) -> SplitNode {
        switch self {
        case .pane(let pane):
            let copy = Pane(content: content(pane))
            map[pane.id] = copy.id
            return .pane(copy)
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.duplicated(content, map: &map),
                          second: second.duplicated(content, map: &map))
        }
    }
}

extension Tab {
    public func pane(_ id: PaneID) -> Pane? { root.pane(id) }

    /// Takes pane `id` out: the tab that is left (nil when it was the last pane: the tab closes) and the pane.
    /// Nil when the pane is not in this tab.
    public func detaching(_ id: PaneID) -> (rest: Tab?, pane: Pane)? {
        guard let pane = pane(id) else { return nil }
        return (closing(id), pane)
    }

    /// Puts `pane` next to pane `target` on its `edge` side, or along that edge of the whole tab when `target` is
    /// nil (or not in this tab). The moved pane takes focus; zoom ends.
    public func inserting(_ pane: Pane, beside target: PaneID?, edge: Direction) -> Tab {
        inserting(tree: .pane(pane), focus: pane.id, beside: target, edge: edge)
    }

    /// Another tab's whole split tree joins this one along `edge` (Move Tab into Window as a Split); its focused
    /// pane keeps focus.
    public func merging(_ other: Tab, beside target: PaneID? = nil, edge: Direction) -> Tab {
        inserting(tree: other.root, focus: other.focused, beside: target, edge: edge)
    }

    private func inserting(tree: SplitNode, focus: PaneID, beside target: PaneID?, edge: Direction) -> Tab {
        let newRoot = target.flatMap { root.contains($0) ? root.inserting(tree, beside: $0, edge: edge) : nil }
            ?? root.inserting(tree, atEdge: edge)
        return Tab(id: id, title: title, color: color, root: newRoot, focused: focus, zoomed: nil)
    }

    /// Panes `a` and `b` of this tab trade places; focus stays on the pane it was on. Unchanged unless both are here.
    public func swappingPanes(_ a: PaneID, _ b: PaneID) -> Tab {
        guard a != b, let pa = pane(a), let pb = pane(b) else { return self }
        return replacingRoot(root.swapping(pa, pb))
    }

    /// The focused pane trades places with its neighbour in `direction` (the pane focus would move to); focus
    /// follows the pane. Unchanged when there is no neighbour there.
    public func swappingFocused(_ direction: Direction) -> Tab {
        let neighbour = movingFocus(direction).focused
        guard neighbour != focused else { return self }
        return swappingPanes(focused, neighbour)
    }

    /// The same layout with fresh panes (new ids) whose content comes from `content`, under a new tab id; focus and
    /// zoom on the copies of the focused and zoomed panes.
    public func duplicated(content: (Pane) -> PaneContent) -> Tab {
        var map: [PaneID: PaneID] = [:]
        let copy = root.duplicated(content, map: &map)
        return Tab(title: title, color: color, root: copy, focused: map[focused]!, zoomed: zoomed.flatMap { map[$0] })
    }
}

extension Window {
    public func tabIndex(containing pane: PaneID) -> Int? { tabs.firstIndex { $0.root.contains(pane) } }
    public func tabIndex(of tab: UUID) -> Int? { tabs.firstIndex { $0.id == tab } }
    public func contains(pane: PaneID) -> Bool { tabIndex(containing: pane) != nil }

    /// Selects tab `id` (unchanged when it is not here).
    public func selectingTab(id: UUID) -> Window {
        guard let index = tabIndex(of: id) else { return self }
        return with(selectedIndex: index)
    }

    /// Takes pane `id` out of its tab: the window that is left (its tab closed when the pane was its last; nil when
    /// that was the window's last tab) and the pane. Nil when the pane is not in this window.
    public func detachingPane(_ id: PaneID) -> (rest: Window?, pane: Pane)? {
        guard let index = tabIndex(containing: id), let (rest, pane) = tabs[index].detaching(id) else { return nil }
        guard let rest else { return (closingTab(at: index), pane) }
        var newTabs = tabs
        newTabs[index] = rest
        return (with(tabs: newTabs), pane)
    }

    /// Takes tab `id` out: the window that is left (nil when it was the last tab) and the tab.
    public func detachingTab(_ id: UUID) -> (rest: Window?, tab: Tab)? {
        guard let index = tabIndex(of: id) else { return nil }
        return (closingTab(at: index), tabs[index])
    }

    /// Inserts `tab` at `index` (clamped; nil = after the selected tab) and selects it.
    public func insertingTab(_ tab: Tab, at index: Int?) -> Window {
        let position = min(max(index ?? selectedIndex + 1, 0), tabs.count)
        var newTabs = tabs
        newTabs.insert(tab, at: position)
        return with(tabs: newTabs, selectedIndex: position)
    }

    /// Replaces the tab with the same id.
    func replacingTab(_ tab: Tab) -> Window {
        guard let index = tabIndex(of: tab.id) else { return self }
        var newTabs = tabs
        newTabs[index] = tab
        return with(tabs: newTabs)
    }

    /// The focused pane of the selected tab in a new tab of its own, right after it (iTerm2's Move Session to
    /// Tab). Unchanged when it is the tab's only pane.
    public func movingFocusedPaneToNewTab() -> Window {
        let tab = selectedTab
        guard tab.panes.count > 1, let (rest, pane) = tab.detaching(tab.focused), let rest else { return self }
        return replacingTab(rest).insertingTab(Tab(pane: pane), at: selectedIndex + 1)
    }
}
