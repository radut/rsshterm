import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@Suite struct JumpSwitcherTests {
    let a = OpenShell(id: PaneID(), title: "root@build: ~/src", host: "build.example.com", directory: "/root/src",
                      lastUsed: Date(timeIntervalSince1970: 100))
    let b = OpenShell(id: PaneID(), title: "bash", host: nil, directory: "/home/u/notes", lastUsed: Date(timeIntervalSince1970: 300))
    let c = OpenShell(id: PaneID(), title: "Web Prod 1", host: "web1.example.com", directory: nil,
                      lastUsed: Date(timeIntervalSince1970: 200))
    let web = Server(name: "Web Prod 1", host: "web1.example.com", username: "deploy")
    let db = Server(name: "db", host: "db.example.com", username: "pg")

    @Test func emptyQueryListsShellsMostRecentFirstThenServers() {
        let r = JumpSwitcher.results(query: "", openShells: [a, b, c], servers: [web, db])
        #expect(r == [.shell(b.id), .shell(c.id), .shell(a.id), .newSession(db.id), .newSession(web.id)])
    }

    @Test func queryFiltersShellsByTitleHostOrDirectoryAndRanksThemFirst() {
        let r = JumpSwitcher.results(query: "web", openShells: [a, b, c], servers: [web, db])
        #expect(r == [.shell(c.id), .newSession(web.id)])
        #expect(JumpSwitcher.results(query: "notes", openShells: [a, b, c], servers: []) == [.shell(b.id)])
        #expect(JumpSwitcher.results(query: "build src", openShells: [a, b, c], servers: []) == [.shell(a.id)])
    }

    @Test func noMatchIsEmptyAndLimitApplies() {
        #expect(JumpSwitcher.results(query: "zzz", openShells: [a, b, c], servers: [web, db]).isEmpty)
        #expect(JumpSwitcher.results(query: "", openShells: [a, b, c], servers: [web, db], limit: 2).count == 2)
    }
}
