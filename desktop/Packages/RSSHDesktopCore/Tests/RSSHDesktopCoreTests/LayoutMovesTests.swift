import Foundation
import Testing
@testable import RSSHDesktopCore

private func pid(_ n: Int) -> PaneID { PaneID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
private func pane(_ n: Int) -> Pane { Pane(id: pid(n), content: .localShell()) }
private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", n))! }

/// Tab `n` with panes `ns` side by side (split right one after another).
private func tab(_ n: Int, _ ns: [Int]) -> Tab {
    var t = Tab(id: uuid(n), pane: pane(ns[0]))
    for p in ns.dropFirst() { t = t.splitting(.right, with: pane(p)) }
    return t
}

private func ratioSum(_ node: SplitNode) -> Bool {
    guard case .split(_, let r, let a, let b) = node else { return true }
    return r >= SplitNode.minimumRatio && r <= 1 - SplitNode.minimumRatio && ratioSum(a) && ratioSum(b)
}

@Suite struct PaneMovesTests {
    @Test func detachingKeepsTheRestAndClosesALoneTab() throws {
        let t = tab(1, [1, 2])
        let (rest, moved) = try #require(t.detaching(pid(2)))
        #expect(moved.id == pid(2))
        #expect(rest?.paneIDs == [pid(1)])
        #expect(rest?.focused == pid(1))
        #expect(Tab(pane: pane(3)).detaching(pid(3))?.rest == nil)
        #expect(t.detaching(pid(9)) == nil)
    }

    @Test(arguments: Direction.allCases)
    func insertingBesideAPaneSplitsItInHalf(_ edge: Direction) throws {
        let t = tab(1, [1, 2]).inserting(pane(3), beside: pid(2), edge: edge)
        #expect(t.focused == pid(3))
        #expect(t.zoomed == nil)
        let frames = t.root.frames()
        let p2 = try #require(frames[pid(2)]), p3 = try #require(frames[pid(3)])
        #expect(abs(p2.width * p2.height - p3.width * p3.height) < 1e-9) // equal halves of the old pane
        switch edge {
        case .left: #expect(p3.maxX <= p2.x + 1e-9)
        case .right: #expect(p3.x >= p2.maxX - 1e-9)
        case .up: #expect(p3.maxY <= p2.y + 1e-9)
        case .down: #expect(p3.y >= p2.maxY - 1e-9)
        }
        #expect(frames[pid(1)]?.width == 0.5) // the other pane keeps its size
    }

    @Test func insertingAtATabEdgeGivesTheRowOneMoreEqualSlot() {
        let three = tab(1, [1, 2]).splitting(.right, with: pane(3)).equalized()
        let four = three.inserting(pane(4), beside: nil, edge: .right)
        let widths = four.root.frames().mapValues(\.width)
        #expect(abs(widths[pid(4)]! - 0.25) < 1e-9)
        #expect(four.paneIDs.last == pid(4))
        let below = three.inserting(pane(4), beside: nil, edge: .down)
        #expect(abs(below.root.frames()[pid(4)]!.height - 0.5) < 1e-9)
        #expect(below.root.frames()[pid(4)]!.width == 1)
        #expect(ratioSum(four.root) && ratioSum(below.root))
    }

    @Test func insertingBesideAMissingPaneFallsBackToTheTabEdge() {
        let t = tab(1, [1]).inserting(pane(2), beside: pid(9), edge: .right)
        #expect(t.paneIDs == [pid(1), pid(2)])
    }

    @Test func zoomEndsWhenAPaneArrives() {
        let zoomed = tab(1, [1, 2]).togglingZoom()
        #expect(zoomed.zoomed != nil)
        #expect(zoomed.inserting(pane(3), beside: pid(1), edge: .down).zoomed == nil)
    }

    @Test func swappingTradesPlacesAndKeepsSizes() {
        let t = tab(1, [1, 2]).resizing(pid(1), axis: .horizontal, by: 0.2) // 0.7 / 0.3
        let swapped = t.swappingPanes(pid(1), pid(2))
        #expect(swapped.paneIDs == [pid(2), pid(1)])
        #expect(abs(swapped.root.frames()[pid(2)]!.width - 0.7) < 1e-9)
        #expect(swapped.focused == t.focused)
        #expect(t.swappingPanes(pid(1), pid(1)) == t)
    }

    @Test func swappingWithTheNeighbourFollowsThePane() {
        let t = tab(1, [1, 2]).focusing(pid(1))
        let swapped = t.swappingFocused(.right)
        #expect(swapped.paneIDs == [pid(2), pid(1)])
        #expect(swapped.focused == pid(1))
        #expect(t.swappingFocused(.left) == t) // nothing on the left
    }

    @Test func duplicatingCopiesTheShapeWithNewPanes() {
        let t = tab(1, [1, 2]).renamed("work").recolored(.green)
        let copy = t.duplicated { _ in .localShell(directory: "/tmp") }
        #expect(copy.id != t.id)
        #expect(copy.panes.count == 2)
        #expect(Set(copy.paneIDs).isDisjoint(with: t.paneIDs))
        #expect(copy.panes.allSatisfy { $0.content == .localShell(directory: "/tmp") })
        #expect(copy.title == "work" && copy.color == .green)
        #expect(copy.root.frames().values.map(\.width).sorted() == t.root.frames().values.map(\.width).sorted())
        #expect(copy.focused == copy.paneIDs[1]) // the copy of the focused pane
    }

    @Test func movingTheFocusedPaneToANewTab() {
        let w = Window(tabs: [tab(1, [1, 2]), tab(2, [3])])
        let moved = w.movingFocusedPaneToNewTab()
        #expect(moved.tabs.map(\.paneIDs) == [[pid(1)], [pid(2)], [pid(3)]])
        #expect(moved.selectedIndex == 1)
        // A lone pane already is its tab.
        #expect(moved.movingFocusedPaneToNewTab() == moved)
        #expect(w.applying(.movePaneToNewTab, newPane: { pane(9) })?.tabs.map(\.paneIDs) == moved.tabs.map(\.paneIDs))
    }

    @Test func tabColourAndWindowTitleRoundTrip() throws {
        let w = Window(tabs: [tab(1, [1]).recolored(.purple)]).retitled("  prod  ")
        #expect(w.title == "prod")
        let back = try JSONDecoder().decode(Window.self, from: JSONEncoder().encode(w))
        #expect(back == w)
        #expect(w.retitled(" ").title == nil)
        // Older files have neither; a colour from a newer app is dropped.
        let json = try JSONEncoder().encode(tab(1, [1]))
        var object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        object["color"] = "ultraviolet"
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.color == nil)
    }
}

@Suite struct WindowMovesTests {
    // Window A: tab 1 [1, 2], tab 2 [3]. Window B: tab 3 [4].
    private var windows: [Window] {
        [Window(id: uuid(100), tabs: [tab(1, [1, 2]), tab(2, [3])]), Window(id: uuid(200), tabs: [tab(3, [4])])]
    }

    @Test func paneToNewTabInAnotherWindow() throws {
        let move = try #require(LayoutMoves.moving(pane: pid(2), to: .newTab(window: uuid(200)), in: windows))
        #expect(move.windows.map { $0.tabs.map(\.paneIDs) } == [[[pid(1)], [pid(3)]], [[pid(4)], [pid(2)]]])
        #expect(move.focusedWindow == uuid(200) && move.focusedPane == pid(2))
        #expect(move.windows[1].selectedTab.focused == pid(2))
        #expect(move.closedWindows(from: windows).isEmpty)
    }

    @Test func paneToNewWindowOpensItAfterTheSource() throws {
        let move = try #require(LayoutMoves.moving(pane: pid(1), to: .newWindow(id: uuid(300)), in: windows))
        #expect(move.windows.map(\.id) == [uuid(100), uuid(300), uuid(200)])
        #expect(move.windows[1].tabs.map(\.paneIDs) == [[pid(1)]])
        #expect(move.openedWindows(from: windows) == [uuid(300)])
        #expect(move.windows[0].tabs[0].paneIDs == [pid(2)])
    }

    @Test func theLastPaneLeavingClosesTabAndWindow() throws {
        let move = try #require(LayoutMoves.moving(pane: pid(4), to: .beside(pane: pid(3), edge: .down), in: windows))
        #expect(move.windows.map(\.id) == [uuid(100)])
        #expect(move.closedWindows(from: windows) == [uuid(200)])
        let a = move.windows[0]
        #expect(a.selectedTab.id == uuid(2)) // the tab it joined is selected
        #expect(a.selectedTab.paneIDs == [pid(3), pid(4)])
        #expect(a.selectedTab.focused == pid(4))
        let tabClosing = try #require(LayoutMoves.moving(pane: pid(3), to: .tabEdge(tab: uuid(1), edge: .right), in: windows))
        #expect(tabClosing.windows[0].tabs.map(\.id) == [uuid(1)])
        #expect(tabClosing.windows[0].tabs[0].paneIDs == [pid(1), pid(2), pid(3)])
    }

    @Test func movesThatChangeNothingAreNil() {
        let lone = [Window(id: uuid(100), tabs: [tab(1, [1])])]
        #expect(LayoutMoves.moving(pane: pid(1), to: .newWindow(), in: lone) == nil)
        #expect(LayoutMoves.moving(pane: pid(1), to: .newTab(window: uuid(100)), in: lone) == nil)
        #expect(LayoutMoves.moving(pane: pid(1), to: .beside(pane: pid(1), edge: .left), in: windows) == nil)
        #expect(LayoutMoves.moving(pane: pid(3), to: .tabEdge(tab: uuid(2), edge: .left), in: windows) == nil)
        #expect(LayoutMoves.moving(pane: pid(9), to: .newWindow(), in: windows) == nil)
        #expect(LayoutMoves.moving(pane: pid(1), to: .newTab(window: uuid(999)), in: windows) == nil)
        #expect(LayoutMoves.moving(tab: uuid(3), to: .newWindow(), in: windows) == nil) // already alone
        #expect(LayoutMoves.moving(tab: uuid(1), to: .split(tab: uuid(1), edge: .right), in: windows) == nil)
        #expect(LayoutMoves.mergingAll(into: uuid(100), in: lone) == nil)
    }

    @Test func paneWithinItsTabMovesToTheOtherSide() throws {
        let move = try #require(LayoutMoves.moving(pane: pid(1), to: .beside(pane: pid(2), edge: .down), in: windows))
        let t = move.windows[0].tabs[0]
        #expect(t.paneIDs == [pid(2), pid(1)])
        #expect(t.root.frames()[pid(1)] == UnitRect(x: 0, y: 0.5, width: 1, height: 0.5))
    }

    @Test func tabToAnotherWindowAtAnIndex() throws {
        let move = try #require(LayoutMoves.moving(tab: uuid(2), to: .window(uuid(200), index: 0), in: windows))
        #expect(move.windows[1].tabs.map(\.id) == [uuid(2), uuid(3)])
        #expect(move.windows[1].selectedIndex == 0)
        #expect(move.windows[0].tabs.map(\.id) == [uuid(1)])
        #expect(move.focusedPane == pid(3))
    }

    @Test func tabReorderWithinItsWindow() throws {
        let move = try #require(LayoutMoves.moving(tab: uuid(1), to: .window(uuid(100), index: 1), in: windows))
        #expect(move.windows[0].tabs.map(\.id) == [uuid(2), uuid(1)])
        #expect(move.windows[0].selectedTab.id == uuid(1))
    }

    @Test func lastTabLeavingClosesItsWindow() throws {
        let move = try #require(LayoutMoves.moving(tab: uuid(3), to: .window(uuid(100)), in: windows))
        #expect(move.closedWindows(from: windows) == [uuid(200)])
        #expect(move.windows[0].tabs.map(\.id) == [uuid(1), uuid(3), uuid(2)]) // after the selected tab
    }

    @Test func tabToNewWindow() throws {
        let move = try #require(LayoutMoves.moving(tab: uuid(2), to: .newWindow(id: uuid(300)), in: windows))
        #expect(move.windows.map(\.id) == [uuid(100), uuid(300), uuid(200)])
        #expect(move.focusedWindow == uuid(300))
    }

    @Test func tabIntoAnotherTabAsASplit() throws {
        let move = try #require(LayoutMoves.moving(tab: uuid(1), to: .split(tab: uuid(3), edge: .right), in: windows))
        #expect(move.windows.count == 2)
        let joined = move.windows[1].selectedTab
        #expect(joined.paneIDs == [pid(4), pid(1), pid(2)])
        #expect(joined.focused == pid(2)) // the moved tab's focused pane
        let widths = joined.root.frames().mapValues(\.width)
        #expect(abs(widths[pid(4)]! - 1.0 / 3) < 1e-9) // one slot of three, like the moved panes
        #expect(ratioSum(joined.root))
    }

    @Test func mergeAllWindowsKeepsEveryTab() throws {
        let three = windows + [Window(id: uuid(300), tabs: [tab(4, [5])], broadcastsInput: true)]
        let move = try #require(LayoutMoves.mergingAll(into: uuid(200), in: three))
        #expect(move.windows.count == 1)
        #expect(move.windows[0].id == uuid(200))
        #expect(move.windows[0].tabs.map(\.id) == [uuid(3), uuid(1), uuid(2), uuid(4)])
        #expect(move.windows[0].selectedIndex == 0)
        #expect(move.windows[0].broadcastsInput)
        #expect(move.closedWindows(from: three) == [uuid(100), uuid(300)])
    }

    @Test func swappingAcrossWindows() throws {
        let move = try #require(LayoutMoves.swapping(pid(1), pid(4), in: windows))
        #expect(move.windows[0].tabs[0].paneIDs == [pid(4), pid(2)])
        #expect(move.windows[1].tabs[0].paneIDs == [pid(1)])
        #expect(move.windows[1].tabs[0].focused == pid(1))
        #expect(move.focusedWindow == uuid(200))
        #expect(LayoutMoves.swapping(pid(1), pid(1), in: windows) == nil)
    }

    @Test func everyPaneSurvivesEveryMove() throws {
        let before = Set(windows.flatMap { $0.tabs.flatMap(\.paneIDs) })
        let moves: [LayoutMove?] = [
            LayoutMoves.moving(pane: pid(2), to: .newWindow(), in: windows),
            LayoutMoves.moving(pane: pid(4), to: .tabEdge(tab: uuid(1), edge: .up), in: windows),
            LayoutMoves.moving(tab: uuid(1), to: .split(tab: uuid(2), beside: pid(3), edge: .left), in: windows),
            LayoutMoves.mergingAll(into: uuid(100), in: windows),
        ]
        for move in moves {
            let m = try #require(move)
            #expect(Set(m.windows.flatMap { $0.tabs.flatMap(\.paneIDs) }) == before)
            #expect(m.windows.allSatisfy { $0.tabs.allSatisfy { ratioSum($0.root) } })
        }
    }

    @Test func broadcastFollowsTheMovedPane() throws {
        // Hand-picked panes keep receiving wherever they go; "current tab" reaches the tab the pane is in now.
        let manual = BroadcastState().broadcasting(to: [pid(2), pid(4)])
        let move = try #require(LayoutMoves.moving(pane: pid(2), to: .newWindow(), in: windows))
        #expect(manual.pruned(existing: Set(move.windows.flatMap { $0.tabs.flatMap(\.paneIDs) })) == manual)
        #expect(manual.targets(for: pid(4), windows: move.windows, visible: []) == [pid(4), pid(2)])

        let tabMode = BroadcastState(mode: .currentTab)
        #expect(tabMode.targets(for: pid(3), windows: windows, visible: []) == [pid(3)])
        let joined = try #require(LayoutMoves.moving(pane: pid(1), to: .tabEdge(tab: uuid(2), edge: .right), in: windows))
        #expect(tabMode.targets(for: pid(3), windows: joined.windows, visible: []) == [pid(3), pid(1)])
    }

    @Test func newActionsHaveIdentifiersTitlesAndDefaults() {
        for action in DesktopAction.moveCommands {
            #expect(DesktopAction(identifier: action.identifier) == action)
            #expect(action.category == .moving)
        }
        let mac = Keybindings.defaults(for: .macOS)
        #expect(mac.action(for: try! KeyChord(parsing: "cmd+alt+shift+t")) == .movePaneToNewTab)
        #expect(mac.action(for: try! KeyChord(parsing: "cmd+alt+n")) == .moveTabToNewWindow)
        #expect(mac.action(for: try! KeyChord(parsing: "cmd+alt+shift+left")) == .swapPane(.left))
        let linux = Keybindings.defaults(for: .linux)
        #expect(linux.action(for: try! KeyChord(parsing: "ctrl+shift+alt+n")) == .movePaneToNewWindow)
        #expect(linux.action(for: try! KeyChord(parsing: "ctrl+shift+alt+m")) == .movePaneMode)
        #expect(linux.action(for: try! KeyChord(parsing: "alt+shift+down")) == .swapPane(.down))
    }
}

@Suite struct DropZonesTests {
    private let frames: [PaneID: UnitRect] = [
        pid(1): UnitRect(x: 0, y: 0, width: 0.5, height: 1),
        pid(2): UnitRect(x: 0.5, y: 0, width: 0.5, height: 1),
    ]

    @Test func nearestEdgeOfThePaneUnderThePointer() throws {
        let right = try #require(DropZones.target(x: 0.45, y: 0.5, frames: frames))
        #expect(right.pane == pid(1) && right.edge == .right)
        #expect(right.preview == UnitRect(x: 0.25, y: 0, width: 0.25, height: 1))
        #expect(DropZones.target(x: 0.75, y: 0.05, frames: frames)?.edge == .up)
        #expect(DropZones.target(x: 0.75, y: 0.97, frames: frames)?.edge == .down)
        #expect(DropZones.target(x: 0.52, y: 0.5, frames: frames)?.edge == .left)
        let down = try #require(DropZones.target(x: 0.75, y: 0.97, frames: frames))
        #expect(down.preview == UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(DropZones.target(x: 1.5, y: 0.5, frames: frames) == nil)
    }
}
