import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@Suite struct TabTitlesTests {
    let web = Server(name: "Web Prod 1", host: "web1.example.com", username: "deploy")
    let db = Server(name: "db", host: "203.0.113.5", port: 2222, username: "postgres")

    var context: TabTitleContext {
        TabTitleContext(servers: [web, db], sshConfigText: "Host lab\n  HostName lab.example.net\n  User me\n")
    }

    @Test func sshPaneUsesTheVaultServer() {
        let pane = Pane(content: .ssh(serverID: web.id))
        let label = context.label(for: Tab(pane: pane), index: 1, states: [:])
        #expect(label == TabTitleLabel(title: "Web Prod 1", subtitle: "deploy@web1.example.com"))
    }

    @Test func liveShellFactsRefineIt() {
        let pane = Pane(content: .ssh(serverID: web.id))
        var state = PaneTitleState()
        state.terminalTitle = "deploy@web1 › vim /etc/nginx/nginx.conf"
        state.setDirectoryURI("file://web1/etc/nginx")
        let label = context.label(for: Tab(pane: pane), index: 1, states: [pane.id: state])
        #expect(label.subtitle == "deploy@web1 · vim /etc/nginx/nginx.conf")
    }

    @Test func localPaneWithSSHToAVaultAlias() {
        let pane = Pane(content: .localShell())
        var state = PaneTitleState()
        state.local = LocalProcessFacts(foreground: ["ssh", "web-prod-1"], cwd: "/home/me", user: "me", host: "box")
        let label = context.label(for: Tab(pane: pane), index: 2, states: [pane.id: state])
        #expect(label.title == "Web Prod 1")
        #expect(label.subtitle == "deploy@web1.example.com")
        state.local = LocalProcessFacts(foreground: ["ssh", "lab"], cwd: "/home/me", user: "me", host: "box")
        #expect(context.label(for: Tab(pane: pane), index: 2, states: [pane.id: state]).title == "me@lab.example.net")
    }

    @Test func manualNameIsLineOneAndClearingItReturnsToAutomatic() {
        let pane = Pane(content: .ssh(serverID: db.id))
        let named = Tab(title: "migrations", pane: pane)
        #expect(context.label(for: named, index: 1, states: [:]).title == "migrations")
        #expect(context.label(for: named.renamed(nil), index: 1, states: [:]).title == "db")
        #expect(context.label(for: named.renamed(""), index: 1, states: [:]).title == "db")
    }

    @Test func theFocusedPaneNamesTheTab() {
        let left = Pane(content: .ssh(serverID: web.id))
        let right = Pane(content: .ssh(serverID: db.id))
        let tab = Tab(pane: left).splitting(.right, with: right)
        #expect(context.label(for: tab, index: 1, states: [:]).title == "db")
        #expect(context.label(for: tab.focusing(left.id), index: 1, states: [:]).title == "Web Prod 1")
    }

    @Test func indexPlaceholder() {
        var ctx = context
        ctx.settings.title = "{index}: {custom|server}"
        let pane = Pane(content: .ssh(serverID: web.id))
        #expect(ctx.label(for: Tab(pane: pane), index: 3, states: [:]).title == "3: Web Prod 1")
    }

    @Test func oscReportsReset() {
        var state = PaneTitleState()
        state.setDirectoryURI("not a uri")
        #expect(state.directory == nil)
        state.setDirectoryURI("file:///tmp")
        #expect(state.directory?.path == "/tmp")
    }
}
