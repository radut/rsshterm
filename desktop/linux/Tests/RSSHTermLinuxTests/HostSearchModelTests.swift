import Foundation
import RSSHKit
import Testing
@testable import RSSHTermLinux

@Suite struct HostSearchModelTests {
    let servers = [
        Server(name: "web prod", host: "web.example.com", username: "deploy"),
        Server(name: "db", host: "db.example.com", username: "pg"),
        Server(name: "backup nas", host: "nas.example.com", username: "admin"),
    ]

    private func model() -> HostSearchModel { HostSearchModel(servers: servers, groups: []) }

    @Test func emptyQueryListsAllByName() {
        let m = model()
        #expect(m.results.map(\.server.name) == ["backup nas", "db", "web prod"])
        #expect(m.selection == 0)
    }

    @Test func typingFiltersAndResetsSelection() {
        var m = model().moving(by: 2)
        m = m.searching("web")
        #expect(m.results.map(\.server.name) == ["web prod"])
        #expect(m.selection == 0)
    }

    @Test func selectionWrapsBothWays() {
        let m = model()
        #expect(m.moving(by: -1).selection == 2)
        #expect(m.moving(by: 3).selection == 0)
    }

    @Test func enterOpensATabShiftEnterASplit() {
        let m = model().moving(by: 1)
        #expect(m.choose(split: false) == .openTab(servers[1].id))
        #expect(m.choose(split: true) == .openSplit(servers[1].id))
        #expect(model().searching("zzz").choose(split: false) == nil)
    }

    @Test func rowTextShowsUserAtHost() {
        let r = model().searching("db").results[0]
        #expect(HostSearchModel.subtitle(r) == "pg@db.example.com")
        let p = Server(name: "x", host: "h", port: 2222, username: "u")
        #expect(HostSearchModel(servers: [p], groups: []).results.map(HostSearchModel.subtitle) == ["u@h:2222"])
    }
}
