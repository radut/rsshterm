import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@Suite struct RemoteDesktopSearchTests {
    let gateway = Server(name: "gateway", host: "gw.example.com", username: "ops")
    let office = ServerGroup(name: "Office")
    let desktops: [RemoteDesktop]

    init() {
        desktops = [
            RemoteDesktop(name: "Mac mini", kind: .appleScreenSharing, host: "localhost", groupID: office.id,
                          tunnelServerID: gateway.id),
            RemoteDesktop(name: "Win11", kind: .rdp, host: "10.0.0.9", tunnelServerID: gateway.id),
            RemoteDesktop(name: "lab screen", kind: .vnc, host: "vnc.example.org", transport: .direct),
        ]
    }

    @Test func findsByNameKindHostFolderAndTunnelServer() {
        func names(_ q: String) -> [String] {
            RemoteDesktopSearch.search(q, desktops: desktops, groups: [office], servers: [gateway]).map(\.name)
        }
        #expect(names("mini") == ["Mac mini"])
        #expect(names("rdp") == ["Win11"])
        #expect(names("vnc.example") == ["lab screen"])
        #expect(names("office") == ["Mac mini"])
        #expect(Set(names("gateway")) == ["Mac mini", "Win11"])
        #expect(names("").count == 3)
        #expect(names("nothing-like-this").isEmpty)
    }

    @Test func jumpSwitcherOffersScreensAfterServers() {
        let results = JumpSwitcher.results(query: "mac", openShells: [], servers: [gateway], groups: [office],
                                           remoteDesktops: desktops)
        #expect(results == [.openScreen(desktops[0].id)])
        let empty = JumpSwitcher.results(query: "", openShells: [], servers: [gateway], remoteDesktops: desktops)
        #expect(!empty.contains(.openScreen(desktops[0].id))) // an empty query lists open shells only
        let both = JumpSwitcher.results(query: "g", openShells: [], servers: [gateway], remoteDesktops: desktops)
        let firstScreen = both.firstIndex { if case .openScreen = $0 { true } else { false } }
        let lastServer = both.lastIndex { if case .newSession = $0 { true } else { false } }
        if let firstScreen, let lastServer { #expect(firstScreen > lastServer) }
    }
}
