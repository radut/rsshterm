import Foundation
import Testing
@testable import RSSHDesktopCore

@Suite struct DividerTests {
    /// a | (b over c)
    func tab() -> (Tab, Pane, Pane, Pane) {
        let a = Pane(content: .localShell()), b = Pane(content: .localShell()), c = Pane(content: .localShell())
        let t = Tab(pane: a).splitting(.right, with: b).focusing(b.id).splitting(.down, with: c)
        return (t, a, b, c)
    }

    @Test func dividersOfTheTree() {
        let (t, _, _, _) = tab()
        let dividers = t.dividers
        #expect(dividers.count == 2)
        let vertical = dividers.first { $0.axis == .horizontal }!
        #expect(vertical.path == [])
        #expect(vertical.position == 0.5)
        #expect(vertical.span == UnitRect(x: 0, y: 0, width: 1, height: 1))
        let horizontal = dividers.first { $0.axis == .vertical }!
        #expect(horizontal.path == [1])
        #expect(horizontal.position == 0.5)
        #expect(horizontal.span == UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    @Test func hitTestingFindsTheDividerUnderThePoint() {
        let (t, _, _, _) = tab()
        #expect(SplitDivider.hit(x: 0.502, y: 0.2, in: t.dividers, tolerance: 0.01)?.path == [])
        #expect(SplitDivider.hit(x: 0.8, y: 0.495, in: t.dividers, tolerance: 0.01)?.path == [1])
        // The right column's divider does not reach into the left pane.
        #expect(SplitDivider.hit(x: 0.2, y: 0.5, in: t.dividers, tolerance: 0.01) == nil)
    }

    @Test func movingADividerSetsItsSplitRatio() {
        let (t, a, b, c) = tab()
        let moved = t.movingDivider([], to: 0.3)
        #expect(moved.visibleFrames[a.id]?.width == 0.3)
        let inner = moved.movingDivider([1], to: 0.75)  // y 0.75 of the right column = ratio 0.75
        #expect(abs(inner.visibleFrames[b.id]!.height - 0.75) < 1e-9)
        #expect(abs(inner.visibleFrames[c.id]!.y - 0.75) < 1e-9)
        // Clamped to the minimum share; an unknown path changes nothing.
        #expect(t.movingDivider([], to: 0.01).visibleFrames[a.id]!.width == SplitNode.minimumRatio)
        #expect(t.movingDivider([0, 1], to: 0.3) == t)
    }

    @Test func noDividersWhileZoomed() {
        let (t, _, _, _) = tab()
        #expect(t.togglingZoom().dividers.isEmpty)
    }

    @Test func mappingPanesKeepsTheTree() {
        let (t, a, _, c) = tab()
        let mapped = t.mappingPanes { Pane(id: $0.id, content: .localShell(directory: "/tmp")) }
        #expect(mapped.paneIDs == t.paneIDs)
        #expect(mapped.visibleFrames == t.visibleFrames)
        #expect(mapped.panes.allSatisfy { $0.content == .localShell(directory: "/tmp") })
        #expect(mapped.focused == c.id)
        #expect(mapped.panes.first?.id == a.id)
    }
}

@Suite struct RemoteDesktopPaneTests {
    @Test func aScreenIsAPaneLikeATerminal() throws {
        let id = UUID()
        let tab = Tab(pane: Pane(content: .localShell())).splitting(.right, with: Pane(content: .remoteDesktop(id: id)))
        #expect(tab.focusedPane.content == .remoteDesktop(id: id))
        let data = try JSONEncoder().encode(Session(windows: [Window(tabs: [tab])]))
        let back = try JSONDecoder().decode(Session.self, from: data)
        #expect(back.windows[0].tabs[0].panes.map(\.content) == [.localShell(), .remoteDesktop(id: id)])
    }
}
