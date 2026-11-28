import Foundation

/// A drag of a pane or a tab, from start to drop, as both desktop apps run it (iTerm2's feel): what is dragged,
/// where it is let go, and the layout that results. The apps only find the spot under the pointer and draw.
public enum DragDrop {
    public enum Item: Equatable, Sendable {
        case pane(PaneID)
        case tab(UUID)
    }

    /// Where a drag ended.
    public enum Spot: Equatable, Sendable {
        /// Over a pane of a window's selected tab, in one of its zones.
        case pane(DropZones.Target)
        /// Over a window's tab bar, at insertion slot `slot` (0...tab count, counted before the drop).
        case tabBar(window: UUID, slot: Int)
        /// Outside every window: a window of its own, with this id.
        case outside(newWindow: UUID)
        /// Escape, or let go where nothing takes it.
        case cancelled
    }

    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Size: Equatable, Sendable {
        public let width: Double
        public let height: Double
        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// The layout after `item` is dropped on `spot`; nil when nothing changes (cancelled, dropped back on itself or
    /// in its own place), and the app then leaves every window as it was.
    public static func move(_ item: Item, to spot: Spot, in windows: [Window]) -> LayoutMove? {
        switch (item, spot) {
        case (_, .cancelled):
            return nil
        case (.pane(let id), .pane(let target)):
            guard target.pane != id else { return nil }
            switch target.zone {
            case .center: return LayoutMoves.swapping(id, target.pane, in: windows)
            case .edge(let edge): return LayoutMoves.moving(pane: id, to: .beside(pane: target.pane, edge: edge), in: windows)
            }
        case (.pane(let id), .tabBar(let windowID, let slot)):
            guard let index = paneSlot(id, slot, windowID, windows) else { return nil }
            return LayoutMoves.moving(pane: id, to: .newTab(window: windowID, index: index), in: windows)
        case (.pane(let id), .outside(let newID)):
            return LayoutMoves.moving(pane: id, to: .newWindow(id: newID), in: windows)
        case (.tab(let id), .pane(let target)):
            guard let window = windows.first(where: { $0.contains(pane: target.pane) }),
                  let tab = window.tabs.first(where: { $0.root.contains(target.pane) }), tab.id != id else { return nil }
            return LayoutMoves.moving(tab: id, to: .split(tab: tab.id, beside: target.pane, edge: target.edge),
                                      in: windows)
        case (.tab(let id), .tabBar(let windowID, let slot)):
            let own = windows.first { $0.id == windowID }?.tabIndex(of: id)
            guard let index = TabInsertion.destination(slot: slot, dragged: own) else { return nil }
            return LayoutMoves.moving(tab: id, to: .window(windowID, index: index), in: windows)
        case (.tab(let id), .outside(let newID)):
            return LayoutMoves.moving(tab: id, to: .newWindow(id: newID), in: windows)
        }
    }

    /// The new tab's index for a pane dropped at `slot`: a pane alone in its tab of the same window leaves that tab
    /// first, so slots after it count one less; its own place (either side of its tab) is nil (no move).
    private static func paneSlot(_ id: PaneID, _ slot: Int, _ windowID: UUID, _ windows: [Window]) -> Int? {
        guard let window = windows.first(where: { $0.id == windowID }),
              let own = window.tabs.firstIndex(where: { $0.root.contains(id) }), window.tabs[own].paneIDs.count == 1
        else { return slot }
        return TabInsertion.destination(slot: slot, dragged: own)
    }

    /// The spot of a drag that no window took: Escape, or let go over a window (nothing there took it) cancels;
    /// let go outside every window, it becomes a window of its own.
    public static func endedSpot(escaped: Bool, overAWindow: Bool, newWindow: UUID) -> Spot {
        escaped || overAWindow ? .cancelled : .outside(newWindow: newWindow)
    }

    /// The drag image's size: half the pane (iTerm2's snapshot), its longer side at most `maxSide`.
    public static func imageSize(pane: Size, maxSide: Double) -> Size {
        guard pane.width > 0, pane.height > 0 else { return Size(width: 1, height: 1) }
        let scale = min(0.5, maxSide / max(pane.width, pane.height))
        return Size(width: (pane.width * scale).rounded(), height: (pane.height * scale).rounded())
    }

    /// The top-left corner of a window of `size` that keeps the point grabbed (`grab`, a fraction of the image)
    /// under `pointer`. Coordinates grow right and down.
    public static func newWindowOrigin(pointer: Point, grab: Point, size: Size) -> Point {
        Point(x: pointer.x - grab.x * size.width, y: pointer.y - grab.y * size.height)
    }
}
