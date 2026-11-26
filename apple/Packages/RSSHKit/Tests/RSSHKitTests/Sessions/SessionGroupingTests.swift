import Foundation
import Testing
@testable import RSSHKit

@Suite struct SessionGroupingTests {
    let home = ServerGroup(name: "Home")
    let cloud = ServerGroup(name: "Cloud")
    var web: Server { Server(name: "web-1", host: "10.0.0.1", username: "root", groupID: cloud.id) }
    var nas: Server { Server(name: "nas", host: "10.0.0.2", username: "admin", groupID: home.id) }
    let loose = Server(name: "loose", host: "10.0.0.3", username: "me")

    private func info(_ serverID: UUID, _ title: String, at minute: Int) -> OpenSessionInfo {
        OpenSessionInfo(id: UUID(), serverID: serverID, title: title,
                        openedAt: Date(timeIntervalSince1970: Double(minute) * 60))
    }

    @Test func foldersInServerListOrderThenOther() {
        let web = web, nas = nas
        let sessions = [info(loose.id, "loose", at: 1), info(web.id, "web-1", at: 2), info(nas.id, "nas", at: 3)]
        let sections = SessionGrouping.sections(sessions, servers: [web, nas, loose], groups: [home, cloud])
        #expect(sections.map(\.title) == ["Home", "Cloud", "Other"])
        #expect(sections.map(\.groupID) == [home.id, cloud.id, nil])
        #expect(sections.map { $0.entries.map(\.title) } == [["nas"], ["web-1"], ["loose"]])
    }

    @Test func otherHasNoHeaderWhenItIsTheOnlySection() {
        let quick = info(UUID(), "root@demo", at: 1)
        let sections = SessionGrouping.sections([quick, info(loose.id, "loose", at: 2)],
                                                servers: [loose], groups: [home])
        #expect(sections.count == 1)
        #expect(sections[0].title == nil)
        #expect(sections[0].entries.count == 2)
    }

    @Test func quickConnectSessionsGoUnderOther() {
        let nas = nas
        let sections = SessionGrouping.sections([info(nas.id, "nas", at: 1), info(UUID(), "root@demo", at: 2)],
                                                servers: [nas], groups: [home])
        #expect(sections.map(\.title) == ["Home", "Other"])
        #expect(sections[1].entries.map(\.title) == ["root@demo"])
    }

    @Test func renamedFolderShowsItsNewName() {
        let nas = nas
        var renamed = home
        renamed.name = "House"
        let sections = SessionGrouping.sections([info(nas.id, "nas", at: 1)], servers: [nas], groups: [renamed])
        #expect(sections.map(\.title) == ["House"])
    }

    @Test func deletedFolderOrDeletedServerFallsBackToOther() {
        // The folder is gone but the server still points at it, and a server deleted while its session is open.
        let sections = SessionGrouping.sections([info(nas.id, "nas", at: 1), info(UUID(), "gone", at: 2)],
                                                servers: [nas], groups: [])
        #expect(sections.count == 1)
        #expect(sections[0].groupID == nil)
        #expect(sections[0].entries.map(\.title) == ["nas", "gone"])
    }

    @Test func sameServerSessionsAreNumberedInOpeningOrder() {
        let web = web
        let first = info(web.id, "web-1", at: 1), second = info(web.id, "web-1", at: 5), other = info(loose.id, "loose", at: 3)
        let sections = SessionGrouping.sections([first, other, second], servers: [web, loose], groups: [cloud])
        #expect(sections[0].entries.map(\.title) == ["web-1 #1", "web-1 #2"])
        #expect(sections[0].entries.map(\.number) == [1, 2])
        #expect(sections[1].entries.map(\.title) == ["loose"])
        #expect(sections[1].entries[0].number == nil)
    }

    @Test func numbersCloseUpWhenOneCloses() {
        let web = web
        let numbers = SessionGrouping.numbers([info(web.id, "web-1", at: 5)])
        #expect(numbers.isEmpty)
    }

    @Test func flatOrderFollowsTheSections() {
        let web = web, nas = nas
        let sessions = [info(web.id, "web-1", at: 1), info(nas.id, "nas", at: 2)]
        let sections = SessionGrouping.sections(sessions, servers: [web, nas], groups: [home, cloud])
        #expect(SessionGrouping.flatOrder(sections) == [sessions[1].id, sessions[0].id])
    }
}

@Suite struct SessionOpenDecisionTests {
    @Test func noneOpenConnects() {
        #expect(SessionOpenDecision.decide(openSessions: [], explicitNew: false) == .connect)
    }

    @Test func alreadyOpenAsks() {
        let ids = [UUID(), UUID()]
        #expect(SessionOpenDecision.decide(openSessions: ids, explicitNew: false) == .ask(ids))
    }

    @Test func explicitNewSessionConnectsWithoutAsking() {
        #expect(SessionOpenDecision.decide(openSessions: [UUID()], explicitNew: true) == .connect)
    }
}
