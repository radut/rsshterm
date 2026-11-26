import Foundation
import Testing
@testable import RSSHKit

@Suite struct DiscoveredImportTests {
    let lab = ServerGroup(name: "Lab")
    let vault: Vault

    init() {
        vault = Vault(groups: [lab], servers: [Server(name: "nas", host: "192.0.2.10", username: "admin")])
    }

    let found = [
        DiscoveredHost(host: "192.0.2.10"),
        DiscoveredHost(host: "192.0.2.11", dnsName: "pi.example.com"),
        DiscoveredHost(host: "192.0.2.12", port: 2222, serviceName: "Office box"),
        DiscoveredHost(host: "192.0.2.13"),
    ]

    @Test func newFolderGetsEveryHostNotSavedYet() throws {
        let result = try vault.addingDiscovered(found, to: .newFolder(" 192.0.2.0/24 "), username: "root")
        let folder = try #require(result.vault.groups.first { $0.name == "192.0.2.0/24" })
        #expect(result.added.map(\.name) == ["pi.example.com", "Office box", "192.0.2.13"])
        #expect(result.added.allSatisfy { $0.groupID == folder.id && $0.username == "root" && $0.credentialID == nil })
        #expect(result.added.map(\.port) == [22, 2222, 22])
        #expect(result.skipped.map(\.host) == ["192.0.2.10"])
        #expect(result.vault.servers.count == 4)
        #expect(vault.servers.count == 1)
    }

    @Test func existingFolderByNameOrIDAndTopLevel() throws {
        let byName = try vault.addingDiscovered([found[3]], to: .newFolder("lab"), username: "")
        #expect(byName.vault.groups.count == 1)
        #expect(byName.added.first?.groupID == lab.id)
        let byID = try vault.addingDiscovered([found[3]], to: .folder(lab.id), username: "")
        #expect(byID.added.first?.groupID == lab.id)
        let top = try vault.addingDiscovered([found[3]], to: .ungrouped, username: " ")
        #expect(top.added.first?.groupID == nil)
        #expect(top.added.first?.username == "")
    }

    @Test func nothingNewCreatesNoFolder() throws {
        let result = try vault.addingDiscovered([DiscoveredHost(host: "192.0.2.10")], to: .newFolder("Scan"), username: "")
        #expect(result.added.isEmpty)
        #expect(result.vault == vault)
    }

    @Test func duplicatesInTheListAreAddedOnce() throws {
        let twice = [DiscoveredHost(host: "192.0.2.20"), DiscoveredHost(host: "192.0.2.20")]
        let result = try vault.addingDiscovered(twice, to: .ungrouped, username: "")
        #expect(result.added.count == 1)
        #expect(result.skipped.count == 1)
    }

    @Test func refusesUnknownFolderAndEmptyName() {
        #expect(throws: VaultEditError.unknownGroup) {
            try vault.addingDiscovered(found, to: .folder(UUID()), username: "")
        }
        #expect(throws: VaultEditError.emptyName) {
            try vault.addingDiscovered(found, to: .newFolder("  "), username: "")
        }
    }

    // MARK: login and jump hosts

    @Test func savedCredentialGoesOnEveryNewServer() throws {
        let key = Credential(label: "lab key", kind: .privateKey(pem: OpenSSHKeyVectors.ed25519PEM, passphrase: nil))
        let start = try vault.addingCredential(key)
        let result = try start.addingDiscovered(found, to: .ungrouped, username: "root", login: .saved(key.id))
        #expect(result.added.count == 3)
        #expect(result.added.allSatisfy { $0.credentialID == key.id })
        #expect(result.vault.credentials == [key])
        #expect(result.credential == nil)
    }

    @Test func newPasswordIsSavedOnceForAllHosts() throws {
        let login = DiscoveredLogin.newPassword("s3cret", label: DiscoveredLogin.label(username: "root", range: "192.0.2.0/24"))
        let result = try vault.addingDiscovered(found, to: .newFolder("192.0.2.0/24"), username: "root", login: login)
        let saved = try #require(result.credential)
        #expect(saved.label == "root@192.0.2.0/24")
        #expect(saved.kind == .password("s3cret"))
        #expect(result.vault.credentials == [saved])
        #expect(result.added.count == 3 && result.added.allSatisfy { $0.credentialID == saved.id })
        #expect(result.skipped.map(\.host) == ["192.0.2.10"])
        #expect(result.vault.groups.contains { $0.name == "192.0.2.0/24" })
    }

    @Test func newKeyIsImportedOnce() throws {
        let key = Credential(label: "scan key", kind: .privateKey(pem: OpenSSHKeyVectors.ed25519PEM, passphrase: nil))
        let result = try vault.addingDiscovered(Array(found[1...2]), to: .ungrouped, username: "pi", login: .new(key))
        #expect(result.vault.credentials.map(\.id) == [key.id])
        #expect(result.added.allSatisfy { $0.credentialID == key.id })
    }

    @Test func nothingNewSavesNoPassword() throws {
        let result = try vault.addingDiscovered([found[0]], to: .newFolder("Scan"), username: "root",
                                                login: .newPassword("s3cret", label: "root@scan"))
        #expect(result.added.isEmpty && result.credential == nil)
        #expect(result.vault == vault)
    }

    @Test func labelWithoutUserOrRange() {
        #expect(DiscoveredLogin.label(username: " root ", range: " 192.0.2.0/28 ") == "root@192.0.2.0/28")
        #expect(DiscoveredLogin.label(username: "", range: "192.0.2.0/28") == "192.0.2.0/28 password")
        #expect(DiscoveredLogin.label(username: "root", range: "") == "root password")
        #expect(DiscoveredLogin.label(username: "", range: "") == "Scan password")
    }

    @Test func refusesUnknownCredentialEmptyPasswordAndBadKey() {
        #expect(throws: VaultEditError.unknownCredential) {
            try vault.addingDiscovered(found, to: .ungrouped, username: "root", login: .saved(UUID()))
        }
        #expect(throws: VaultEditError.emptySecret) {
            try vault.addingDiscovered(found, to: .ungrouped, username: "root", login: .newPassword("", label: "x"))
        }
        #expect(throws: VaultEditError.self) {
            try vault.addingDiscovered(found, to: .ungrouped, username: "root",
                                       login: .new(Credential(label: "bad", kind: .privateKey(pem: "nope", passphrase: nil))))
        }
    }

    @Test func jumpHostsGoOnEveryNewServer() throws {
        let bastion = Server(name: "bastion", host: "bastion.example.com", username: "ops")
        let gateway = Server(name: "gw", host: "gw.example.com", username: "ops")
        let start = try vault.addingServer(bastion).addingServer(gateway)
        let jumps: [JumpHost] = [.server(bastion.id), .server(gateway.id)]
        let result = try start.addingDiscovered(found, to: .ungrouped, username: "root", jumpHosts: jumps)
        #expect(result.added.count == 3 && result.added.allSatisfy { $0.jumpHosts == jumps })
        let hops = try result.vault.connectionHops(to: result.added[0])
        #expect(hops.map(\.name) == ["bastion", "gw", "pi.example.com"])
    }

    @Test func refusesUnknownJumpServerAndTooManyHops() throws {
        let gone = UUID()
        #expect(throws: VaultEditError.jumpChain(.missingServer(gone))) {
            try vault.addingDiscovered(found, to: .ungrouped, username: "root", jumpHosts: [.server(gone)])
        }
        let nas = vault.servers[0]
        let tooMany = Array(repeating: JumpHost.server(nas.id), count: JumpChain.maxHops + 1)
        #expect(throws: VaultEditError.jumpChain(.tooDeep(max: JumpChain.maxHops))) {
            try vault.addingDiscovered(found, to: .ungrouped, username: "root", jumpHosts: tooMany)
        }
    }

    // MARK: screens found open (3389 RDP, 5900 VNC)

    @Test func sshAndRDPOfOneHostBecomeOneServerWithBothServices() throws {
        let hosts = [DiscoveredHost(host: "192.0.2.30"), DiscoveredHost(host: "192.0.2.30", port: 3389),
                     DiscoveredHost(host: "192.0.2.31", port: 5900)]
        let result = try vault.addingDiscovered(hosts, to: .ungrouped, username: "admin")
        #expect(result.added.map(\.host) == ["192.0.2.30", "192.0.2.31"])
        let both = result.added[0], vncOnly = result.added[1]
        #expect(both.sshEnabled && both.port == 22 && result.vault.service(.rdp, of: both.id)?.port == 3389)
        #expect(!vncOnly.sshEnabled && result.vault.service(.vnc, of: vncOnly.id)?.transport == .direct)
        #expect(result.screens.count == 2 && result.skipped.isEmpty)
    }

    @Test func aScreenOfASavedHostIsAddedToItOnlyWhenAsked() throws {
        let rdp = DiscoveredHost(host: "192.0.2.10", port: 3389)
        #expect(vault.serversForDiscoveredScreens([rdp, found[1]]).map(\.name) == ["nas"])
        let separate = try vault.addingDiscovered([rdp], to: .ungrouped, username: "admin")
        #expect(separate.added.count == 1 && !separate.added[0].sshEnabled)
        #expect(separate.vault.services(of: vault.servers[0].id).isEmpty)

        let joined = try vault.addingDiscovered([rdp], to: .ungrouped, username: "admin", screensJoinSavedServers: true)
        #expect(joined.added.isEmpty && joined.screens.count == 1)
        let screen = try #require(joined.vault.service(.rdp, of: vault.servers[0].id))
        #expect(screen.host == "localhost" && screen.tunnelServerID == vault.servers[0].id)
        // Asked again for the same host: that service is there already, so it is skipped.
        let again = try joined.vault.addingDiscovered([rdp], to: .ungrouped, username: "admin", screensJoinSavedServers: true)
        #expect(again.screens.isEmpty && again.skipped == [rdp])
    }

    @Test func hasServerIgnoresCaseButNotPort() {
        let named = Vault(servers: [Server(name: "w", host: "Web.Example.com", username: "u")])
        #expect(named.hasServer(host: "web.example.com", port: 22))
        #expect(!named.hasServer(host: "web.example.com", port: 2222))
    }

    @Test func mergingKeepsOrderAndFillsGaps() {
        let list = [DiscoveredHost]()
            .adding(DiscoveredHost(host: "192.0.2.20"))
            .adding(DiscoveredHost(host: "192.0.2.3", banner: SSHBanner(line: "SSH-2.0-OpenSSH_9.7")))
            .adding(DiscoveredHost(host: "192.0.2.3", serviceName: "printer", answered: [.ping]))
            .adding(DiscoveredHost(host: "nas.local"))
            .adding(DiscoveredHost(host: "192.0.2.3", port: 2222))
        #expect(list.map(\.id) == ["192.0.2.3:22", "192.0.2.3:2222", "192.0.2.20:22", "nas.local:22"])
        #expect(list[0].serviceName == "printer")
        #expect(list[0].answered == [.ssh, .ping])
        #expect(list[0].banner?.software == "OpenSSH_9.7")
        #expect(list[1].suggestedName == "192.0.2.3:2222")
    }
}
