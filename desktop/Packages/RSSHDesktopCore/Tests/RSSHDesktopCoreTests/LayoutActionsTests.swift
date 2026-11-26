import Foundation
import Testing
@testable import RSSHDesktopCore

@Suite struct LayoutActionsTests {
    private let shell = { Pane(content: .localShell()) }

    @Test func keysDriveTheLayout() throws {
        var window = Window(tabs: [Tab(pane: shell())])
        window = try #require(window.applying(.splitRight, newPane: shell))
        window = try #require(window.applying(.splitDown, newPane: shell))
        #expect(window.selectedTab.panes.count == 3)
        let third = window.selectedTab.focused
        window = try #require(window.applying(.focus(.left), newPane: shell))
        #expect(window.selectedTab.focused != third)
        window = try #require(window.applying(.previousPane, newPane: shell))
        #expect(window.selectedTab.focused == third) // first pane → previous wraps to the last
        window = try #require(window.applying(.resizePane(.left), newPane: shell))
        #expect(abs(window.selectedTab.root.frames()[third]!.width - 0.55) < 1e-9)
        window = try #require(window.applying(.toggleZoom, newPane: shell))
        #expect(window.selectedTab.zoomed == third)
        window = try #require(window.applying(.newTab, newPane: shell))
        #expect(window.tabs.count == 2 && window.selectedIndex == 1)
        window = try #require(window.applying(.moveTabLeft, newPane: shell))
        #expect(window.selectedIndex == 0 && window.selectedTab.panes.count == 1)
        window = try #require(window.applying(.selectTab(9), newPane: shell))
        #expect(window.selectedIndex == 1)
        window = try #require(window.applying(.broadcastCurrentTab, newPane: shell))
        #expect(window.broadcastsInput)
        #expect(window.applying(.hostSearch, newPane: shell) == window)
    }

    @Test func closingEverythingClosesTheWindow() throws {
        var window: Window? = Window(tabs: [Tab(pane: shell())]).applying(.splitRight, newPane: shell)
        window = window?.applying(.closePane, newPane: shell)
        #expect(window?.selectedTab.panes.count == 1)
        #expect(window?.applying(.closePane, newPane: shell) == nil)
    }

    @Test func nextPaneCyclesInReadingOrder() {
        let tab = Tab(pane: shell()).splitting(.right, with: shell()).splitting(.down, with: shell())
        let ids = tab.paneIDs
        #expect(tab.focusingNextPane().focused == ids[0])
        #expect(tab.focusingNextPane().focusingNextPane().focused == ids[1])
        #expect(tab.focusingPreviousPane().focused == ids[1])
    }
}
