import Foundation
import Testing
@testable import RSSHDesktopCore

private func pid(_ n: Int) -> PaneID { PaneID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
private func pane(_ n: Int) -> Pane { Pane(id: pid(n), content: .localShell()) }
private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", n))! }
private func wid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0002-%012d", n))! }

private func tab(_ n: Int, _ ns: [Int]) -> Tab {
    var t = Tab(id: uuid(n), pane: pane(ns[0]))
    for p in ns.dropFirst() { t = t.splitting(.right, with: pane(p)) }
    return t
}

@Suite struct DropZoneTests {
    private let square = UnitRect(x: 0, y: 0, width: 1, height: 1)

    @Test func edgesAndCentreOfARect() {
        #expect(DropZones.zone(x: 0.05, y: 0.5, in: square) == .edge(.left))
        #expect(DropZones.zone(x: 0.95, y: 0.5, in: square) == .edge(.right))
        #expect(DropZones.zone(x: 0.5, y: 0.05, in: square) == .edge(.up))
        #expect(DropZones.zone(x: 0.5, y: 0.95, in: square) == .edge(.down))
        #expect(DropZones.zone(x: 0.5, y: 0.5, in: square) == .center)
        #expect(DropZones.zone(x: 0.6, y: 0.45, in: square) == .center)
        #expect(DropZones.zone(x: 1.2, y: 0.5, in: square) == nil)
    }

    @Test func noCentreWhenNotOffered() {
        #expect(DropZones.zone(x: 0.55, y: 0.5, in: square, center: false) == .edge(.right))
        #expect(DropZones.zone(x: 0.5, y: 0.4, in: square, center: false) == .edge(.up))
    }

    @Test func zonesFollowAnOffsetRect() {
        let r = UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        #expect(DropZones.zone(x: 0.98, y: 0.75, in: r) == .edge(.right))
        #expect(DropZones.zone(x: 0.75, y: 0.75, in: r) == .center)
        #expect(DropZones.zone(x: 0.25, y: 0.75, in: r) == nil)
    }

    @Test func highlightIsTheHalfOrTheWholePane() {
        let r = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        #expect(DropZones.highlight(.edge(.right), in: r) == UnitRect(x: 0.75, y: 0, width: 0.25, height: 1))
        #expect(DropZones.highlight(.edge(.up), in: r) == UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(DropZones.highlight(.center, in: r) == r)
    }

    @Test func targetCarriesTheZoneAndItsHighlight() throws {
        let frames: [PaneID: UnitRect] = [pid(1): UnitRect(x: 0, y: 0, width: 0.5, height: 1),
                                          pid(2): UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        let centre = try #require(DropZones.target(x: 0.74, y: 0.5, frames: frames, center: true))
        #expect(centre.pane == pid(2) && centre.zone == .center && centre.edge == .left)
        #expect(centre.preview == frames[pid(2)])
        let noCentre = try #require(DropZones.target(x: 0.76, y: 0.5, frames: frames))
        #expect(noCentre.zone == .edge(.right)) // no centre unless asked for (a tab, and the callers before it)
    }
}

@Suite struct TabInsertionTests {
    /// Three tabs 100 wide starting at 4.
    private let frames = [TabInsertion.Span(x: 4, width: 100), .init(x: 105, width: 100), .init(x: 206, width: 100)]

    @Test func slotIsBeforeTheTabWhoseMiddleIsRightOfThePointer() {
        #expect(TabInsertion.slot(x: 0, frames: frames) == 0)
        #expect(TabInsertion.slot(x: 50, frames: frames) == 0)
        #expect(TabInsertion.slot(x: 60, frames: frames) == 1)
        #expect(TabInsertion.slot(x: 200, frames: frames) == 2)
        #expect(TabInsertion.slot(x: 280, frames: frames) == 3)
        #expect(TabInsertion.slot(x: 900, frames: frames) == 3)
        #expect(TabInsertion.slot(x: 10, frames: []) == 0)
    }

    @Test func droppingATabNextToItselfChangesNothing() {
        #expect(TabInsertion.destination(slot: 1, dragged: 1) == nil)
        #expect(TabInsertion.destination(slot: 2, dragged: 1) == nil)
        #expect(TabInsertion.destination(slot: 0, dragged: 2) == 0)
        #expect(TabInsertion.destination(slot: 3, dragged: 0) == 2)
        #expect(TabInsertion.destination(slot: 2, dragged: nil) == 2)
    }

    @Test func neighboursSlideToOpenTheGap() {
        let widths: [Double] = [100, 100, 100, 100]
        // Tab 0 dragged to slot 3: tabs 1 and 2 slide left into its place.
        #expect(TabInsertion.offsets(widths: widths, spacing: 1, dragged: 0, slot: 3, gap: 100) == [0, -101, -101, 0])
        // Tab 3 dragged to slot 1: tabs 1 and 2 slide right.
        #expect(TabInsertion.offsets(widths: widths, spacing: 1, dragged: 3, slot: 1, gap: 100) == [0, 101, 101, 0])
        // A tab from another window at slot 2: tabs from 2 on slide right by the gap.
        #expect(TabInsertion.offsets(widths: widths, spacing: 1, dragged: nil, slot: 2, gap: 80) == [0, 0, 81, 81])
        // Over its own place, or nowhere: nothing moves.
        #expect(TabInsertion.offsets(widths: widths, spacing: 1, dragged: 1, slot: 2, gap: 100) == [0, 0, 0, 0])
        #expect(TabInsertion.offsets(widths: widths, spacing: 1, dragged: 1, slot: nil, gap: 100) == [0, 0, 0, 0])
    }

    @Test func gapStartsWhereTheNeighboursMadeRoom() {
        let widths: [Double] = [100, 100, 100, 100]
        #expect(TabInsertion.gapX(widths: widths, spacing: 1, dragged: 0, slot: 3) == 202)
        #expect(TabInsertion.gapX(widths: widths, spacing: 1, dragged: 3, slot: 1) == 101)
        #expect(TabInsertion.gapX(widths: widths, spacing: 1, dragged: nil, slot: 4) == 404)
        #expect(TabInsertion.gapX(widths: widths, spacing: 1, dragged: nil, slot: 0) == 0)
        #expect(TabInsertion.gapX(widths: widths, spacing: 1, dragged: 1, slot: 1) == nil)
    }

    @Test func markerSitsBetweenTabs() {
        #expect(TabInsertion.markerX(slot: 0, frames: frames) == 4)
        #expect(TabInsertion.markerX(slot: 1, frames: frames) == 104.5)
        #expect(TabInsertion.markerX(slot: 3, frames: frames) == 306)
        #expect(TabInsertion.markerX(slot: 0, frames: []) == 0)
    }
}

@Suite struct DragDropTests {
    /// Window 1: tab 1 with panes 1 | 2, tab 2 with pane 3. Window 2: tab 3 with pane 4.
    private let windows = [
        Window(id: wid(1), tabs: [tab(1, [1, 2]), tab(2, [3])]),
        Window(id: wid(2), tabs: [tab(3, [4])]),
    ]

    private func spot(_ pane: Int, _ zone: DropZone) -> DragDrop.Spot {
        .pane(DropZones.Target(pane: pid(pane), zone: zone, preview: UnitRect(x: 0, y: 0, width: 1, height: 1)))
    }

    @Test func paneOnTheRightHalfOfAnotherEndsOnItsRight() throws {
        // A | B with A dropped on the right half of B: B | A, A on the right.
        let move = try #require(DragDrop.move(.pane(pid(1)), to: spot(2, .edge(.right)), in: windows))
        let frames = move.windows[0].tabs[0].root.frames()
        #expect(move.windows[0].tabs[0].paneIDs == [pid(2), pid(1)])
        #expect(frames[pid(1)]!.x > frames[pid(2)]!.x)
        #expect(move.focusedPane == pid(1))
    }

    @Test(arguments: [(Direction.left, true, false), (.right, true, true), (.up, false, false), (.down, false, true)])
    func everyEdgeZoneSplitsThatWay(_ edge: Direction, _ horizontal: Bool, _ after: Bool) throws {
        let move = try #require(DragDrop.move(.pane(pid(3)), to: spot(4, .edge(edge)), in: windows))
        let target = try #require(move.windows.first { $0.id == wid(2) })
        let frames = target.tabs[0].root.frames()
        let moved = frames[pid(3)]!, other = frames[pid(4)]!
        if horizontal {
            #expect(moved.height == 1 && other.height == 1)
            #expect(after ? moved.x > other.x : moved.x < other.x)
        } else {
            #expect(moved.width == 1 && other.width == 1)
            #expect(after ? moved.y > other.y : moved.y < other.y)
        }
        // Pane 3 was alone in tab 2: the tab closed.
        #expect(move.windows[0].tabs.count == 1)
    }

    @Test func centreSwaps() throws {
        let move = try #require(DragDrop.move(.pane(pid(1)), to: spot(4, .center), in: windows))
        #expect(move.windows[0].tabs[0].paneIDs == [pid(4), pid(2)])
        #expect(move.windows[1].tabs[0].paneIDs == [pid(1)])
    }

    @Test func droppingOnItselfOrCancellingChangesNothing() {
        #expect(DragDrop.move(.pane(pid(1)), to: spot(1, .edge(.left)), in: windows) == nil)
        #expect(DragDrop.move(.pane(pid(1)), to: spot(1, .center), in: windows) == nil)
        #expect(DragDrop.move(.pane(pid(1)), to: .cancelled, in: windows) == nil)
        #expect(DragDrop.move(.tab(uuid(1)), to: .cancelled, in: windows) == nil)
        // A tab put back in its own place.
        #expect(DragDrop.move(.tab(uuid(1)), to: .tabBar(window: wid(1), slot: 0), in: windows) == nil)
        #expect(DragDrop.move(.tab(uuid(1)), to: .tabBar(window: wid(1), slot: 1), in: windows) == nil)
        // A lone pane of a lone tab dragged out: it already is that window.
        #expect(DragDrop.move(.pane(pid(4)), to: .outside(newWindow: wid(9)), in: windows) == nil)
        // A tab onto a pane of its own.
        #expect(DragDrop.move(.tab(uuid(1)), to: spot(2, .edge(.right)), in: windows) == nil)
    }

    @Test func aLonePaneOnItsOwnTabsPlaceChangesNothing() throws {
        #expect(DragDrop.move(.pane(pid(3)), to: .tabBar(window: wid(1), slot: 1), in: windows) == nil)
        #expect(DragDrop.move(.pane(pid(3)), to: .tabBar(window: wid(1), slot: 2), in: windows) == nil)
        let first = try #require(DragDrop.move(.pane(pid(3)), to: .tabBar(window: wid(1), slot: 0), in: windows))
        #expect(first.windows[0].tabs.map(\.paneIDs) == [[pid(3)], [pid(1), pid(2)]])
    }

    @Test func paneOnTheTabBarBecomesATabAtTheMarker() throws {
        let move = try #require(DragDrop.move(.pane(pid(2)), to: .tabBar(window: wid(1), slot: 1), in: windows))
        #expect(move.windows[0].tabs.map(\.paneIDs) == [[pid(1)], [pid(2)], [pid(3)]])
        #expect(move.windows[0].selectedTab.paneIDs == [pid(2)])
    }

    @Test func tabReordersWithinItsBarAndMovesToAnotherBar() throws {
        let reorder = try #require(DragDrop.move(.tab(uuid(1)), to: .tabBar(window: wid(1), slot: 2), in: windows))
        #expect(reorder.windows[0].tabs.map(\.id) == [uuid(2), uuid(1)])
        let across = try #require(DragDrop.move(.tab(uuid(2)), to: .tabBar(window: wid(2), slot: 0), in: windows))
        #expect(across.windows[1].tabs.map(\.id) == [uuid(2), uuid(3)])
        #expect(across.windows[0].tabs.map(\.id) == [uuid(1)])
    }

    @Test func tabOnAPaneEdgeBecomesASplitButNeverSwaps() throws {
        let split = try #require(DragDrop.move(.tab(uuid(2)), to: spot(4, .edge(.left)), in: windows))
        #expect(split.windows[1].tabs[0].paneIDs == [pid(3), pid(4)])
        let centre = try #require(DragDrop.move(.tab(uuid(2)), to: spot(4, .center), in: windows))
        #expect(centre.windows[1].tabs[0].paneIDs == [pid(4), pid(3)]) // the centre counts as the right edge
    }

    @Test func outsideEveryWindowMakesANewWindow() throws {
        let pane = try #require(DragDrop.move(.pane(pid(2)), to: .outside(newWindow: wid(9)), in: windows))
        #expect(pane.focusedWindow == wid(9))
        #expect(pane.windows.first { $0.id == wid(9) }?.tabs.first?.paneIDs == [pid(2)])
        let tab = try #require(DragDrop.move(.tab(uuid(2)), to: .outside(newWindow: wid(9)), in: windows))
        #expect(tab.windows.first { $0.id == wid(9) }?.tabs.map(\.id) == [uuid(2)])
    }

    @Test func spotFromAnEndedDrag() {
        // Escape, or let go over a window where nothing takes it: cancelled. Let go outside every window: new one.
        #expect(DragDrop.endedSpot(escaped: true, overAWindow: false, newWindow: wid(9)) == .cancelled)
        #expect(DragDrop.endedSpot(escaped: false, overAWindow: true, newWindow: wid(9)) == .cancelled)
        #expect(DragDrop.endedSpot(escaped: false, overAWindow: false, newWindow: wid(9)) == .outside(newWindow: wid(9)))
    }

    @Test func dragImageIsScaledDownAndTheDetachedOneTakesTheWindowSize() {
        let small = DragDrop.imageSize(pane: .init(width: 1200, height: 800), maxSide: 360)
        #expect(small == .init(width: 360, height: 240))
        #expect(DragDrop.imageSize(pane: .init(width: 200, height: 100), maxSide: 360) == .init(width: 100, height: 50))
        #expect(DragDrop.imageSize(pane: .init(width: 0, height: 0), maxSide: 360) == .init(width: 1, height: 1))
        // The new window opens with its top-left corner where the image's was: under the pointer, grab point kept.
        let origin = DragDrop.newWindowOrigin(pointer: .init(x: 500, y: 400), grab: .init(x: 0.25, y: 0.1),
                                              size: .init(width: 800, height: 600))
        #expect(origin == .init(x: 300, y: 340))
    }
}
