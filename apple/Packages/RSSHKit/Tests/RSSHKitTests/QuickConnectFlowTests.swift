import Foundation
import Testing
@testable import RSSHKit

@Suite struct QuickHostTests {
    @Test func parsesHostForms() {
        #expect(QuickHost.parse("192.0.2.10") == QuickHost(host: "192.0.2.10"))
        #expect(QuickHost.parse("web.example.com:2222") == QuickHost(host: "web.example.com", port: 2222))
        #expect(QuickHost.parse("ubuntu@192.0.2.11") == QuickHost(username: "ubuntu", host: "192.0.2.11"))
        #expect(QuickHost.parse("u@[2001:db8::1]:22") == QuickHost(username: "u", host: "2001:db8::1", port: 22))
        #expect(QuickHost.parse("2001:db8::1") == QuickHost(host: "2001:db8::1"))
    }

    @Test(arguments: ["", "@h", "a@b@c", "h:0", "h:x", "a b", "h/x"])
    func rejectsNonHosts(_ text: String) {
        #expect(QuickHost.parse(text) == nil)
    }

    @Test func parsesPastedListWithAnySeparator() {
        let list = QuickHost.parseList("192.0.2.1, 192.0.2.2\nroot@192.0.2.3:2200 ;  192.0.2.1 bad:port")
        #expect(list.hosts == [QuickHost(host: "192.0.2.1"), QuickHost(host: "192.0.2.2"),
                               QuickHost(username: "root", host: "192.0.2.3", port: 2200)])
        #expect(list.invalid == ["bad:port"])
    }

    @Test func displayName() {
        #expect(QuickHost(host: "h").displayName == "h")
        #expect(QuickHost(username: "u", host: "h", port: 2200).displayName == "u@h:2200")
        #expect(QuickHost(host: "2001:db8::1", port: 22).displayName == "[2001:db8::1]:22")
    }
}

@Suite struct QuickConnectFlowTests {
    @Test func stepsGoHostsThenUserThenLoginThenConnecting() throws {
        var flow = QuickConnectFlow()
        #expect(flow.step == .hosts)
        flow.addHosts("192.0.2.1 192.0.2.2")
        #expect(flow.step == .user)
        flow.chooseUser("  ")
        #expect(flow.step == .user)
        flow.chooseUser("ubuntu")
        #expect(flow.step == .login)
        let targets = try flow.connect(with: .automatic)
        #expect(flow.step == .connecting)
        #expect(flow.login == .automatic)
        #expect(targets == [ConnectionTarget(host: "192.0.2.1", port: 22, username: "ubuntu"),
                            ConnectionTarget(host: "192.0.2.2", port: 22, username: "ubuntu")])
        flow.stopConnecting()
        #expect(flow.step == .login)
    }

    @Test func hostsWithTheirOwnUserSkipTheUserStep() {
        var flow = QuickConnectFlow()
        flow.addHosts("root@192.0.2.1")
        #expect(!flow.needsUser)
        #expect(flow.step == .login)
        flow.addHosts("192.0.2.2")
        #expect(flow.step == .user)
    }

    @Test func searchAddressPrefillsAndSkipsUser() throws {
        let flow = QuickConnectFlow(address: QuickAddress(username: "root", host: "sv1.example.com", port: 2222))
        #expect(flow.step == .login)
        #expect(try flow.targets() == [ConnectionTarget(host: "sv1.example.com", port: 2222, username: "root")])
    }

    @Test func hostUserAndPortOverrideTheScreensOnes() throws {
        var flow = QuickConnectFlow(port: "2200")
        flow.addHosts("admin@192.0.2.1:22 192.0.2.2")
        flow.chooseUser("root")
        #expect(try flow.targets() == [ConnectionTarget(host: "192.0.2.1", port: 22, username: "admin"),
                                       ConnectionTarget(host: "192.0.2.2", port: 2200, username: "root")])
    }

    @Test func invalidPortStopsConnectAndStaysOnLogin() {
        var flow = QuickConnectFlow(hosts: [QuickHost(host: "h")], port: "99999", username: "root")
        #expect(throws: ConnectionTarget.ValidationError.invalidPort) { try flow.connect(with: .password) }
        #expect(flow.step == .login)
        #expect(flow.login == nil)
    }

    @Test func addingSkipsDuplicatesAndReportsInvalid() {
        var flow = QuickConnectFlow()
        #expect(flow.addHosts("192.0.2.1") == [])
        #expect(flow.addHosts("192.0.2.1, x@") == ["x@"])
        #expect(flow.hosts.count == 1)
        flow.removeHosts(atOffsets: [0])
        #expect(flow.step == .hosts)
    }

    @Test func serverDraftsOnePerHostNamedAfterIt() throws {
        let group = UUID(), key = UUID()
        var flow = QuickConnectFlow()
        flow.addHosts("192.0.2.1\n192.0.2.2:2222")
        flow.chooseUser("ubuntu")
        let drafts = try flow.serverDrafts(groupID: group, credentialID: key)
        #expect(drafts.map(\.name) == ["192.0.2.1", "192.0.2.2"])
        #expect(drafts.map(\.port) == ["22", "2222"])
        #expect(drafts.allSatisfy { $0.username == "ubuntu" && $0.groupID == group && $0.credentialID == key })
        #expect(drafts.allSatisfy { $0.issues.isEmpty })
    }
}
