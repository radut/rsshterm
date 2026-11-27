import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@Suite struct PaneDescriptionTests {
    let web = Server(name: "Web Prod 1", host: "web1.example.com", username: "deploy")
    var context: TabTitleContext { TabTitleContext(servers: [web]) }

    @Test func localShellWithFolderAndProcess() {
        let pane = Pane(content: .localShell())
        var state = PaneTitleState()
        state.local = LocalProcessFacts(foreground: ["vim", "notes.md"], cwd: "/home/me/git", user: "me", host: "box",
                                        home: "/home/me")
        let rows = context.describePanes(windows: [Window(tabs: [Tab(pane: pane)])], states: [pane.id: state],
                                         current: pane.id)
        #expect(rows.count == 1)
        #expect(rows[0].title == context.label(for: Tab(pane: pane), index: 1, states: [pane.id: state]).title)
        #expect(rows[0].title == "me@box")
        #expect(rows[0].subtitle == "me@box · ~/git · vim")
        #expect(rows[0].kind == .localShell)
        #expect(rows[0].location == "Tab 1 › pane 1")
        #expect(rows[0].isCurrent)
    }

    @Test func sshPaneAcrossWindowsAndTabs() {
        let local = Pane(content: .localShell()), ssh = Pane(content: .ssh(serverID: web.id))
        let other = Pane(content: .localShell()), mid = Pane(content: .localShell())
        let windows = [Window(tabs: [Tab(pane: local)]),
                       Window(tabs: [Tab(pane: other), Tab(pane: mid).splitting(.right, with: ssh)])]
        let rows = context.describePanes(windows: windows, states: [:], current: local.id)
        let row = rows.first { $0.id == ssh.id }!
        #expect(row.title == "Web Prod 1")
        #expect(row.subtitle == "deploy@web1.example.com")
        #expect(row.kind == .ssh)
        #expect(row.location == "Window 2 › Tab 2 › pane 2")
        #expect((row.window, row.tab, row.pane) == (2, 2, 2))
        #expect(!row.isCurrent)
        // Layout order: windows, then tabs, then panes.
        #expect(rows.map(\.location) == ["Window 1 › Tab 1 › pane 1", "Window 2 › Tab 1 › pane 1",
                                         "Window 2 › Tab 2 › pane 1", "Window 2 › Tab 2 › pane 2"])
        #expect(row.matches(["web", "tab"]))
        #expect(!row.matches(["postgres"]))
    }

    @Test func nothingKnownYetNamesThePaneNeverABareShell() {
        let a = Pane(content: .localShell()), b = Pane(content: .localShell()), c = Pane(content: .localShell())
        let rows = context.describePanes(windows: [Window(tabs: [Tab(pane: a), Tab(pane: c).splitting(.right, with: b)])],
                                         states: [:], current: nil)
        #expect(rows.last?.title == "Shell — pane 2 in Tab 2")
        #expect(rows.allSatisfy { $0.title != "Shell" && $0.title != TabTitleSettings.fallbackTitle })
        #expect(rows.last?.subtitle == "")
    }

    @Test func theCurrentPaneIsFoundByTheFilter() {
        let a = Pane(content: .localShell())
        let row = context.describePanes(windows: [Window(tabs: [Tab(pane: a)])], states: [:], current: a.id)[0]
        #expect(row.matches(["this", "pane"]))
    }
}
