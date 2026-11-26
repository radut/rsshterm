import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@Suite struct HostSearchTests {
    let home = ServerGroup(name: "Home")
    let cloud = ServerGroup(name: "OpenStack")
    var servers: [Server] {
        [
            Server(name: "pi-hole", host: "dns.example.lan", username: "admin", groupID: home.id),
            Server(name: "web-prod-1", host: "web1.example.com", username: "deploy", groupID: cloud.id),
            Server(name: "web-prod-2", host: "web2.example.com", username: "deploy", groupID: cloud.id),
            Server(name: "Backup NAS", host: "nas.example.lan", port: 2222, username: "root", groupID: home.id),
            Server(name: "db", host: "203.0.113.5", username: "postgres"),
        ]
    }
    var index: HostSearchIndex { HostSearchIndex(servers: servers, groups: [home, cloud]) }

    @Test func emptyQueryListsEveryServerByName() {
        #expect(index.search("").map(\.server.name) == ["Backup NAS", "db", "pi-hole", "web-prod-1", "web-prod-2"])
    }

    @Test func prefixOfNameRanksFirst() {
        #expect(index.search("web").prefix(2).map(\.server.name) == ["web-prod-1", "web-prod-2"])
        #expect(index.search("nas").first?.server.name == "Backup NAS")
    }

    @Test func fuzzySubsequence() {
        #expect(index.search("wp2").first?.server.name == "web-prod-2")
        #expect(index.search("bkn").first?.server.name == "Backup NAS")
    }

    @Test func caseInsensitive() {
        #expect(index.search("BACKUP").first?.server.name == "Backup NAS")
    }

    @Test func matchesHostUserAndGroup() {
        #expect(index.search("203.0.113").map(\.server.name) == ["db"])
        #expect(index.search("postgres").map(\.server.name) == ["db"])
        #expect(Set(index.search("openstack").map(\.server.name)) == ["web-prod-1", "web-prod-2"])
        #expect(index.search("openstack").first?.matchedField == .group)
    }

    @Test func everyWordMustMatch() {
        // "home" (group) and "nas" (name): only the NAS is in Home and called nas
        #expect(index.search("home nas").map(\.server.name) == ["Backup NAS"])
        #expect(index.search("home zzz").isEmpty)
    }

    @Test func userAtHostQuery() {
        #expect(index.search("deploy@web2").first?.server.name == "web-prod-2")
    }

    @Test func noMatchIsEmpty() {
        #expect(index.search("qqq").isEmpty)
    }

    @Test func resultOpensAnSSHTab() {
        let result = index.search("db").first!
        let tab = result.openTab()
        #expect(tab.focusedPane.content == .ssh(serverID: result.server.id))
    }

    @Test func limitCapsResults() {
        #expect(index.search("", limit: 2).count == 2)
    }

    @Test func scorerRewardsWordStartsAndRuns() {
        let start = FuzzyMatcher.score("wp", in: "web-prod")!
        let middle = FuzzyMatcher.score("ep", in: "web-prod")!
        #expect(start > middle)
        #expect(FuzzyMatcher.score("abc", in: "ab") == nil)
        #expect(FuzzyMatcher.score("web", in: "web")! > FuzzyMatcher.score("web", in: "website")!)
    }
}
