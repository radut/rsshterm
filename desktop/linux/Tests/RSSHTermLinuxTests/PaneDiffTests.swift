import RSSHDesktopCore
import Testing
@testable import RSSHTermLinux

@Suite struct PaneDiffTests {
    let shell = { Pane(content: .localShell()) }

    @Test func splitAddsOnePane() {
        let w0 = Window(tabs: [Tab(pane: shell())])
        let w1 = w0.applying(.splitRight, newPane: shell)!
        let diff = PaneDiff(from: w0, to: w1)
        #expect(diff.added.count == 1)
        #expect(diff.added.first?.id == w1.selectedTab.focused)
        #expect(diff.removed.isEmpty)
    }

    @Test func closingATabRemovesAllItsPanes() {
        var w = Window(tabs: [Tab(pane: shell())])
        w = w.applying(.newTab, newPane: shell)!
        w = w.applying(.splitDown, newPane: shell)!
        let doomed = Set(w.selectedTab.paneIDs)
        let after = w.closingTab(at: w.selectedIndex)!
        let diff = PaneDiff(from: w, to: after)
        #expect(Set(diff.removed) == doomed)
        #expect(diff.added.isEmpty)
    }

    @Test func fromNothingEverythingIsNew() {
        let w = Window(tabs: [Tab(pane: shell()), Tab(pane: shell())])
        #expect(PaneDiff(from: nil, to: w).added.count == 2)
        #expect(PaneDiff(from: w, to: nil).removed.count == 2)
    }

    @Test func focusChangeIsNoDiff() {
        let w0 = Window(tabs: [Tab(pane: shell())]).applying(.splitRight, newPane: shell)!
        let w1 = w0.applying(.focus(.left), newPane: shell)!
        #expect(PaneDiff(from: w0, to: w1).isEmpty)
    }
}
