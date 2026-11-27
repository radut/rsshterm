import Foundation

/// Where a moved pane goes.
public enum PaneDestination: Equatable, Sendable {
    /// Its own tab in window `window`, at `index` (nil: after the selected tab).
    case newTab(window: UUID, index: Int? = nil)
    /// Its own window, which gets id `id`.
    case newWindow(id: UUID = UUID())
    /// Next to pane `pane` (any tab, any window), on its `edge` side: a drop on a pane's edge.
    case beside(pane: PaneID, edge: Direction)
    /// Along the `edge` of tab `tab` as a whole: Move Pane to Tab › (right; with the modifier, below).
    case tabEdge(tab: UUID, edge: Direction)
}

/// Where a moved tab goes.
public enum TabDestination: Equatable, Sendable {
    /// Into window `window` at `index` (nil: after its selected tab): a drop on a tab bar, Move Tab to Window ›.
    case window(UUID, index: Int? = nil)
    /// Its own window with id `id`: a tab dragged out of every window, Move Tab to New Window.
    case newWindow(id: UUID = UUID())
    /// Its whole split tree joins tab `tab` along `edge` (or next to pane `beside`): Move Tab into Window as a Split.
    case split(tab: UUID, beside: PaneID? = nil, edge: Direction)
}

/// The windows after a move, and where focus goes: the moved pane (or tab's focused pane) in its window, which the
/// app brings to the front. Windows that lost their last tab are gone from `windows`.
public struct LayoutMove: Equatable, Sendable {
    public let windows: [Window]
    public let focusedWindow: UUID
    public let focusedPane: PaneID

    /// The ids of windows that were in `before` and are not any more (the app closes them).
    public func closedWindows(from before: [Window]) -> [UUID] {
        let now = Set(windows.map(\.id))
        return before.map(\.id).filter { !now.contains($0) }
    }

    /// The ids of windows that are new (the app opens them).
    public func openedWindows(from before: [Window]) -> [UUID] {
        let was = Set(before.map(\.id))
        return windows.map(\.id).filter { !was.contains($0) }
    }
}

/// Moves between tabs and windows over the app's whole set of windows. Pure: each returns the new windows, or nil
/// when the move changes nothing (dropping a pane on itself, a lone tab onto a new window, …). Closing rules: a tab
/// whose last pane moved away closes, so does a window whose last tab moved away. Pane ids never change, so live
/// sessions and the hand-picked broadcast set follow the pane.
public enum LayoutMoves {
    public static func moving(pane id: PaneID, to destination: PaneDestination, in windows: [Window]) -> LayoutMove? {
        guard let sourceIndex = windows.firstIndex(where: { $0.contains(pane: id) }) else { return nil }
        let source = windows[sourceIndex]
        let sourceTab = source.tabs[source.tabIndex(containing: id)!]
        let alone = sourceTab.panes.count == 1
        switch destination {
        case .newTab(let windowID, _) where alone && windowID == source.id && source.tabs.count == 1:
            return nil
        case .newWindow where alone && source.tabs.count == 1:
            return nil
        case .beside(let target, _) where target == id:
            return nil
        case .tabEdge(let tabID, _) where tabID == sourceTab.id && alone:
            return nil
        default:
            break
        }
        guard destinationExists(destination, in: windows) else { return nil }
        let (rest, pane) = source.detachingPane(id)!
        var next = windows
        next[sourceIndex] = rest ?? source // removed below when nil
        let removeSource = rest == nil

        let focusWindow: UUID
        switch destination {
        case .newTab(let windowID, let index):
            let w = next.firstIndex { $0.id == windowID }!
            next[w] = next[w].insertingTab(Tab(pane: pane), at: index)
            focusWindow = windowID
        case .newWindow(let newID):
            next.insert(Window(id: newID, tabs: [Tab(pane: pane)]), at: sourceIndex + 1)
            focusWindow = newID
        case .beside(let target, let edge):
            let w = next.firstIndex { $0.contains(pane: target) }!
            let t = next[w].tabIndex(containing: target)!
            let tab = next[w].tabs[t].inserting(pane, beside: target, edge: edge)
            next[w] = next[w].replacingTab(tab).selectingTab(id: tab.id)
            focusWindow = next[w].id
        case .tabEdge(let tabID, let edge):
            let w = next.firstIndex { $0.tabIndex(of: tabID) != nil }!
            let tab = next[w].tabs[next[w].tabIndex(of: tabID)!].inserting(pane, beside: nil, edge: edge)
            next[w] = next[w].replacingTab(tab).selectingTab(id: tab.id)
            focusWindow = next[w].id
        }
        if removeSource { next.removeAll { $0.id == source.id } }
        return LayoutMove(windows: next, focusedWindow: focusWindow, focusedPane: id)
    }

    /// The destination's window, tab or pane still exists once the pane left (a pane beside itself never does).
    private static func destinationExists(_ destination: PaneDestination, in windows: [Window]) -> Bool {
        switch destination {
        case .newTab(let id, _): windows.contains { $0.id == id }
        case .newWindow(let id): !windows.contains { $0.id == id }
        case .beside(let pane, _): windows.contains { $0.contains(pane: pane) }
        case .tabEdge(let tab, _): windows.contains { $0.tabIndex(of: tab) != nil }
        }
    }

    public static func moving(tab id: UUID, to destination: TabDestination, in windows: [Window]) -> LayoutMove? {
        guard let sourceIndex = windows.firstIndex(where: { $0.tabIndex(of: id) != nil }) else { return nil }
        let source = windows[sourceIndex]
        let fromIndex = source.tabIndex(of: id)!
        switch destination {
        case .newWindow where source.tabs.count == 1:
            return nil
        case .newWindow(let newID) where windows.contains { $0.id == newID }:
            return nil
        case .window(let windowID, let index) where windowID == source.id:
            // A reorder within the window.
            let to = min(max(index ?? source.selectedIndex + 1, 0), source.tabs.count - 1)
            guard to != fromIndex else { return nil }
            let moved = source.movingTab(from: fromIndex, to: to).selectingTab(id: id)
            var next = windows
            next[sourceIndex] = moved
            return LayoutMove(windows: next, focusedWindow: source.id, focusedPane: source.tabs[fromIndex].focused)
        case .window(let windowID, _) where !windows.contains { $0.id == windowID }:
            return nil
        case .split(let tabID, _, _) where tabID == id || !windows.contains { $0.tabIndex(of: tabID) != nil }:
            return nil
        default:
            break
        }
        let (rest, tab) = source.detachingTab(id)!
        var next = windows
        if let rest { next[sourceIndex] = rest }
        let focusWindow: UUID
        switch destination {
        case .window(let windowID, let index):
            let w = next.firstIndex { $0.id == windowID }!
            next[w] = next[w].insertingTab(tab, at: index)
            focusWindow = windowID
        case .newWindow(let newID):
            next.insert(Window(id: newID, tabs: [tab]), at: sourceIndex + 1)
            focusWindow = newID
        case .split(let tabID, let beside, let edge):
            let w = next.firstIndex { $0.tabIndex(of: tabID) != nil }!
            let merged = next[w].tabs[next[w].tabIndex(of: tabID)!].merging(tab, beside: beside, edge: edge)
            next[w] = next[w].replacingTab(merged).selectingTab(id: merged.id)
            focusWindow = next[w].id
        }
        if rest == nil { next.removeAll { $0.id == source.id } }
        return LayoutMove(windows: next, focusedWindow: focusWindow, focusedPane: tab.focused)
    }

    /// Window › Merge All Windows: every tab of every window into window `target`, in window order after its own
    /// tabs; the target's selected tab stays selected, it broadcasts when any window did. Nil with one window.
    public static func mergingAll(into target: UUID, in windows: [Window]) -> LayoutMove? {
        guard windows.count > 1, let keep = windows.first(where: { $0.id == target }) else { return nil }
        let others = windows.filter { $0.id != target }
        let merged = Window(id: keep.id, tabs: keep.tabs + others.flatMap(\.tabs), selectedIndex: keep.selectedIndex,
                            broadcastsInput: windows.contains(where: \.broadcastsInput), title: keep.title)
        return LayoutMove(windows: [merged], focusedWindow: keep.id, focusedPane: keep.selectedTab.focused)
    }

    /// Swap Pane with ›: panes `a` and `b` trade places, wherever they are (two tabs, two windows); focus stays on
    /// `a` in its new place. Nil when either is missing or they are the same pane.
    public static func swapping(_ a: PaneID, _ b: PaneID, in windows: [Window]) -> LayoutMove? {
        guard a != b,
              let pa = windows.lazy.compactMap({ $0.tabs.lazy.compactMap { $0.pane(a) }.first }).first,
              let pb = windows.lazy.compactMap({ $0.tabs.lazy.compactMap { $0.pane(b) }.first }).first
        else { return nil }
        let next = windows.map { window in
            window.with(tabs: window.tabs.map { tab in
                guard tab.root.contains(a) || tab.root.contains(b) else { return tab }
                let swapped = tab.replacingRoot(tab.root.swapping(pa, pb))
                // Focus that pointed at a pane which left this tab follows the pane that came in.
                let focus = swapped.root.contains(tab.focused) ? tab.focused : (tab.focused == a ? b : a)
                return swapped.focusing(focus)
            })
        }
        let w = next.firstIndex { $0.contains(pane: a) }!
        let t = next[w].tabIndex(containing: a)!
        var result = next
        result[w] = next[w].with(selectedIndex: t).replacingTab(next[w].tabs[t].focusing(a))
        return LayoutMove(windows: result, focusedWindow: result[w].id, focusedPane: a)
    }
}
