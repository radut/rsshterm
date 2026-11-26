import Foundation
import Testing
@testable import RSSHDesktopCore

private func pane(_ n: Int) -> Pane {
    Pane(id: PaneID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!), content: .localShell())
}

@Suite struct SplitTreeTests {
    @Test func newTabHasOnePaneFocused() {
        let tab = Tab(pane: pane(1))
        #expect(tab.paneIDs == [pane(1).id])
        #expect(tab.focused == pane(1).id)
    }

    @Test func splitRightPutsNewPaneBesideAndFocusesIt() {
        let tab = Tab(pane: pane(1)).splitting(.right, with: pane(2))
        #expect(tab.paneIDs == [pane(1).id, pane(2).id])
        #expect(tab.focused == pane(2).id)
        guard case .split(let axis, let ratio, _, _) = tab.root else { Issue.record("not a split"); return }
        #expect(axis == .horizontal)
        #expect(ratio == 0.5)
    }

    @Test func splitDownStacksVertically() {
        let tab = Tab(pane: pane(1)).splitting(.down, with: pane(2))
        guard case .split(let axis, _, _, _) = tab.root else { Issue.record("not a split"); return }
        #expect(axis == .vertical)
    }

    @Test func splitLeftAndUpPutNewPaneFirst() {
        #expect(Tab(pane: pane(1)).splitting(.left, with: pane(2)).paneIDs == [pane(2).id, pane(1).id])
        #expect(Tab(pane: pane(1)).splitting(.up, with: pane(2)).paneIDs == [pane(2).id, pane(1).id])
    }

    @Test func originalValueIsUnchanged() {
        let tab = Tab(pane: pane(1))
        _ = tab.splitting(.right, with: pane(2))
        #expect(tab.paneIDs == [pane(1).id])
    }

    @Test func frames() {
        // [1 | [2 / 3]]
        let tab = Tab(pane: pane(1)).splitting(.right, with: pane(2)).splitting(.down, with: pane(3))
        let frames = tab.root.frames()
        #expect(frames[pane(1).id] == UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(frames[pane(2).id] == UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(frames[pane(3).id] == UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    @Test func moveFocusByDirection() {
        // [1 | [2 / 3]], focus on 3
        let tab = Tab(pane: pane(1)).splitting(.right, with: pane(2)).splitting(.down, with: pane(3))
        #expect(tab.focused == pane(3).id)
        #expect(tab.movingFocus(.up).focused == pane(2).id)
        #expect(tab.movingFocus(.left).focused == pane(1).id)
        #expect(tab.movingFocus(.right).focused == pane(3).id) // nothing to the right: unchanged
        #expect(tab.movingFocus(.left).movingFocus(.right).focused == pane(2).id) // ties: the top one
        #expect(tab.movingFocus(.up).movingFocus(.down).focused == pane(3).id)
    }

    @Test func moveFocusPrefersOverlappingNeighbour() {
        // [[1 / 2] | 3]: from 3 left goes to the pane overlapping 3's top edge first (1)
        let tab = Tab(pane: pane(1)).splitting(.down, with: pane(2)).focusing(pane(2).id)
            .splitting(.right, with: pane(3))
        // tree: [1 / [2 | 3]]
        #expect(tab.movingFocus(.up).focused == pane(1).id)
        #expect(tab.movingFocus(.left).focused == pane(2).id)
    }

    @Test func closingAPaneCollapsesItsSplitAndFocusesSibling() {
        let tab = Tab(pane: pane(1)).splitting(.right, with: pane(2)).splitting(.down, with: pane(3))
        let closed = tab.closing(pane(3).id)
        #expect(closed?.paneIDs == [pane(1).id, pane(2).id])
        #expect(closed?.focused == pane(2).id)
        guard case .split(.horizontal, _, .pane, .pane)? = closed?.root else { Issue.record("not collapsed"); return }
    }

    @Test func closingTheLastPaneClosesTheTab() {
        #expect(Tab(pane: pane(1)).closing(pane(1).id) == nil)
    }

    @Test func closingAnUnfocusedPaneKeepsFocus() {
        let tab = Tab(pane: pane(1)).splitting(.right, with: pane(2))
        #expect(tab.closing(pane(1).id)?.focused == pane(2).id)
    }

    @Test func closingTheZoomedPaneUnzooms() {
        let tab = Tab(pane: pane(1)).splitting(.right, with: pane(2)).togglingZoom()
        #expect(tab.zoomed == pane(2).id)
        #expect(tab.closing(pane(2).id)?.zoomed == nil)
    }

    @Test func equalizeGivesEveryPaneOfARowTheSameWidth() {
        // three panes side by side: [1 | [2 | 3]] → 1/3 each
        let tab = Tab(pane: pane(1)).splitting(.right, with: pane(2)).splitting(.right, with: pane(3)).equalized()
        let frames = tab.root.frames()
        for id in tab.paneIDs { #expect(abs(frames[id]!.width - 1.0 / 3) < 1e-9) }
    }

    @Test func resizeMovesTheNearestDividerOnThatAxis() {
        let tab = Tab(pane: pane(1)).splitting(.right, with: pane(2)).splitting(.down, with: pane(3))
        let wider = tab.resizing(pane(3).id, axis: .horizontal, by: -0.1) // grow 3 leftwards
        #expect(abs(wider.root.frames()[pane(3).id]!.width - 0.6) < 1e-9)
        let clamped = tab.resizing(pane(3).id, axis: .horizontal, by: -5)
        #expect(abs(clamped.root.frames()[pane(1).id]!.width - SplitNode.minimumRatio) < 1e-9)
    }

    @Test func zoomTogglesOnTheFocusedPane() {
        let tab = Tab(pane: pane(1)).splitting(.right, with: pane(2))
        let zoomed = tab.togglingZoom()
        #expect(zoomed.zoomed == pane(2).id)
        #expect(zoomed.visibleFrames.keys.sorted { $0.raw.uuidString < $1.raw.uuidString } == [pane(2).id])
        #expect(zoomed.togglingZoom().zoomed == nil)
        // moving focus or splitting leaves zoom
        #expect(zoomed.movingFocus(.left).zoomed == nil)
        #expect(zoomed.splitting(.down, with: pane(3)).zoomed == nil)
    }

    @Test func codableRoundTrip() throws {
        let tab = Tab(pane: pane(1)).splitting(.right, with: Pane(id: pane(2).id, content: .ssh(serverID: UUID())))
            .splitting(.down, with: Pane(id: pane(3).id, content: .localShell(command: ["htop"], directory: "/tmp")))
            .togglingZoom()
        let data = try JSONEncoder().encode(tab)
        #expect(try JSONDecoder().decode(Tab.self, from: data) == tab)
    }

    @Test func decodingRejectsAFocusOutsideTheTree() throws {
        let tab = Tab(pane: pane(1))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object["focused"] = pane(9).id.raw.uuidString
        let json = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Tab.self, from: json) }
    }

    @Test func replacingContentsKeepsTheTree() {
        let a = Pane(content: .localShell())
        let b = Pane(content: .localShell())
        let tab = Tab(pane: a).splitting(.down, with: b).renamed("t").focusing(a.id)
        let moved = tab.replacingContents { pane in
            pane.id == a.id ? .localShell(command: nil, directory: "/tmp") : pane.content
        }
        #expect(moved.paneIDs == tab.paneIDs)
        #expect(moved.focused == a.id)
        #expect(moved.title == "t")
        #expect(moved.root.frames() == tab.root.frames())
        #expect(moved.panes[0].content == .localShell(command: nil, directory: "/tmp"))
        #expect(moved.panes[1].content == b.content)
    }
}
