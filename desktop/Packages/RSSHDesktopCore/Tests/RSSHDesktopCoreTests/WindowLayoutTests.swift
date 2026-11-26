import Foundation
import Testing
@testable import RSSHDesktopCore

private func tab(_ n: Int) -> Tab {
    Tab(pane: Pane(id: PaneID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!), content: .localShell()))
}

@Suite struct WindowLayoutTests {
    private var window: Window { Window(tabs: [tab(1), tab(2), tab(3)]) }

    @Test func addingATabSelectsItAfterTheCurrentOne() {
        let w = window.selectingTab(number: 1).addingTab(tab(4))
        #expect(w.tabs.map(\.focused) == [tab(1), tab(4), tab(2), tab(3)].map(\.focused))
        #expect(w.selectedIndex == 1)
    }

    @Test func selectTabByNumberOneToNine() {
        #expect(window.selectingTab(number: 2).selectedIndex == 1)
        #expect(window.selectingTab(number: 9).selectedIndex == 2) // 9 = last tab, like browsers and iTerm2
        #expect(window.selectingTab(number: 5).selectedIndex == window.selectedIndex) // no 5th tab: unchanged
        #expect(window.selectingTab(number: 0).selectedIndex == window.selectedIndex)
    }

    @Test func nextAndPreviousWrap() {
        let w = window.selectingTab(number: 3)
        #expect(w.selectingNextTab().selectedIndex == 0)
        #expect(w.selectingNextTab().selectingPreviousTab().selectedIndex == 2)
    }

    @Test func closingTheLastPaneOfATabClosesTheTab() {
        let w = window.selectingTab(number: 2).closingFocusedPane()
        #expect(w?.tabs.count == 2)
        #expect(w?.selectedIndex == 1) // the tab that took its place
    }

    @Test func closingTheLastPaneOfTheLastTabClosesTheWindow() {
        #expect(Window(tabs: [tab(1)]).closingFocusedPane() == nil)
    }

    @Test func closingTheRightmostTabSelectsItsLeftNeighbour() {
        #expect(window.selectingTab(number: 3).closingTab(at: 2)?.selectedIndex == 1)
    }

    @Test func movingATab() {
        let w = window.movingTab(from: 0, to: 2)
        #expect(w.tabs.map(\.focused) == [tab(2), tab(3), tab(1)].map(\.focused))
        #expect(w.selectedIndex == 2) // selection follows the moved tab
    }

    @Test func updatingTheSelectedTab() {
        let pane = Pane(content: .localShell())
        let w = window.updatingSelectedTab { $0.splitting(.right, with: pane) }
        #expect(w.selectedTab.focused == pane.id)
    }

    @Test func broadcastToggle() {
        #expect(window.togglingBroadcast().broadcastsInput)
        #expect(!window.togglingBroadcast().togglingBroadcast().broadcastsInput)
    }

    @Test func sessionRoundTrip() throws {
        let session = Session(windows: [window.selectingTab(number: 2), Window(tabs: [tab(7)])])
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(Session.self, from: data) == session)
    }

    @Test func decodingClampsABadSelection() throws {
        let json = String(decoding: try JSONEncoder().encode(window), as: UTF8.self)
            .replacingOccurrences(of: "\"selectedIndex\":0", with: "\"selectedIndex\":42")
        #expect(try JSONDecoder().decode(Window.self, from: Data(json.utf8)).selectedIndex == 2)
    }
}
