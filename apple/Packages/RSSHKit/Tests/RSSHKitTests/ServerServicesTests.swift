import Foundation
import Testing
@testable import RSSHKit

@Suite struct ServerServicesTests {
    let lab = ServerGroup(name: "Lab")
    let pw = Credential(label: "admin pw", kind: .password("x"))
    let key = Credential(label: "key", kind: .privateKey(pem: OpenSSHKeyVectors.ed25519PEM, passphrase: nil))

    private func vault(_ servers: [Server], desktops: [RemoteDesktop] = []) -> Vault {
        Vault(groups: [lab], servers: servers, credentials: [pw, key], remoteDesktops: desktops)
    }

    // MARK: services of a server

    @Test func turningOnRDPAddsAScreenThroughTheServersOwnSSH() throws {
        let win = Server(name: "win", host: "win.example.com", username: "admin", credentialID: pw.id, groupID: lab.id)
        let next = try vault([win]).settingServices(of: win.id, ssh: true, screens: [.rdp])
        let rdp = try #require(next.service(.rdp, of: win.id))
        #expect(rdp.kind == .rdp && rdp.port == 3389 && rdp.serverID == win.id)
        #expect(rdp.transport == .sshShared && rdp.tunnelServerID == win.id && rdp.host == "localhost")
        #expect(rdp.name == "win" && rdp.groupID == lab.id)
        // "Copy from SSH": the account, and the password (a key cannot open a screen).
        #expect(rdp.username == "admin" && rdp.credentialID == pw.id)
        #expect(next.standaloneRemoteDesktops.isEmpty)
        #expect(next.servers[0].sshEnabled)
    }

    @Test func withoutSSHTheScreenGoesDirectAndAKeyIsNotCopied() throws {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi", credentialID: key.id)
        let next = try vault([box]).settingServices(of: box.id, ssh: false, screens: [.vnc])
        #expect(next.servers[0].sshEnabled == false)
        let vnc = try #require(next.service(.vnc, of: box.id))
        #expect(vnc.kind == .vnc && vnc.port == 5900 && vnc.transport == .direct && vnc.host == "192.0.2.5")
        #expect(vnc.tunnelServerID == nil && vnc.credentialID == nil)
    }

    @Test func turningAServiceOffRemovesOnlyThatScreenAndKeepsItsSettings() throws {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi")
        let both = try vault([box]).settingServices(of: box.id, ssh: true, screens: [.rdp, .vnc])
        var rdp = try #require(both.service(.rdp, of: box.id))
        rdp.port = 3390
        let edited = try both.updatingRemoteDesktop(rdp)
        let again = try edited.settingServices(of: box.id, ssh: true, screens: [.rdp])
        #expect(again.service(.vnc, of: box.id) == nil)
        #expect(again.service(.rdp, of: box.id)?.port == 3390)
    }

    @Test func openingIsSSHUnlessItIsOff() throws {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi")
        #expect(vault([box]).opening(box) == .ssh)
        let both = try vault([box]).settingServices(of: box.id, ssh: true, screens: [.vnc, .rdp])
        #expect(both.opening(both.servers[0]) == .ssh)
        #expect(both.services(of: box.id).map(\.kind) == [.rdp, .vnc])
        let off = try both.settingServices(of: box.id, ssh: false, screens: [.vnc, .rdp])
        #expect(off.opening(off.servers[0]) == .screen(try #require(off.service(.rdp, of: box.id)).id))
    }

    @Test func aServerNeedsAtLeastOneService() {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi")
        #expect(throws: VaultEditError.noService) { try vault([box]).settingServices(of: box.id, ssh: false, screens: []) }
        #expect(throws: VaultEditError.unknownServer) { try vault([box]).settingServices(of: UUID(), ssh: true, screens: []) }
    }

    @Test func oneScreenOfEachKindPerServer() throws {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi")
        let next = try vault([box]).settingServices(of: box.id, ssh: true, screens: [.rdp])
        let second = RemoteDesktop(name: "box", kind: .rdp, host: "localhost", tunnelServerID: box.id, serverID: box.id)
        #expect(throws: VaultEditError.serviceExists("Remote Desktop (RDP)")) { try next.addingRemoteDesktop(second) }
        let stray = RemoteDesktop(name: "x", kind: .rdp, host: "h", serverID: UUID())
        #expect(throws: VaultEditError.unknownServer) { try next.addingRemoteDesktop(stray) }
    }

    @Test func renamingOrMovingTheServerCarriesItsScreens() throws {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi")
        let next = try vault([box]).settingServices(of: box.id, ssh: false, screens: [.rdp])
        var moved = next.servers[0]
        moved.name = "desk"
        moved.groupID = lab.id
        moved.host = "192.0.2.6"
        let updated = try next.updatingServer(moved)
        let rdp = try #require(updated.service(.rdp, of: box.id))
        #expect(rdp.name == "desk" && rdp.groupID == lab.id && rdp.host == "192.0.2.6")
    }

    @Test func deletingTheServerDeletesItsScreens() throws {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi")
        let next = try vault([box]).settingServices(of: box.id, ssh: true, screens: [.rdp, .vnc])
        let gone = try next.deletingServers([box.id])
        #expect(gone.remoteDesktops.isEmpty && gone.servers.isEmpty)
    }

    // MARK: merging, never silent

    @Test func suggestsMatchesButMergesOnlyWhenAsked() throws {
        let nas = Server(name: "nas", host: "NAS.example.com", username: "admin", groupID: lab.id)
        let bastion = Server(name: "bastion", host: "bastion.example.com", username: "ops")
        let direct = RemoteDesktop(name: "nas screen", kind: .vnc, host: "nas.example.com")
        let tunnelled = RemoteDesktop(name: "nas rdp", kind: .rdp, host: "localhost", tunnelServerID: nas.id)
        let elsewhere = RemoteDesktop(name: "other", kind: .rdp, host: "other.example.com", tunnelServerID: bastion.id)
        let start = vault([nas, bastion], desktops: [direct, tunnelled, elsewhere])
        #expect(start.mergeSuggestions.map(\.desktop.id) == [direct.id, tunnelled.id])
        #expect(start.mergeSuggestions.allSatisfy { $0.server.id == nas.id })
        #expect(start.remoteDesktops.allSatisfy { $0.serverID == nil })

        let merged = try start.mergingRemoteDesktop(tunnelled.id, into: nas.id)
        let rdp = try #require(merged.service(.rdp, of: nas.id))
        #expect(rdp.id == tunnelled.id && rdp.name == "nas" && rdp.groupID == lab.id && rdp.tunnelServerID == nas.id)
        #expect(merged.mergeSuggestions.map(\.desktop.id) == [direct.id])

        let kept = try merged.keepingSeparate(direct.id)
        #expect(kept.mergeSuggestions.isEmpty)
        #expect(kept.remoteDesktops.first { $0.id == direct.id }?.serverID == nil)
        #expect(kept.standaloneRemoteDesktops.map(\.id) == [direct.id, elsewhere.id])
    }

    @Test func mergeRefusesATakenKindOrUnknownIDs() throws {
        let nas = Server(name: "nas", host: "nas.example.com", username: "admin")
        let a = RemoteDesktop(name: "a", kind: .vnc, host: "nas.example.com")
        let b = RemoteDesktop(name: "b", kind: .vnc, host: "nas.example.com", port: 5901)
        let once = try vault([nas], desktops: [a, b]).mergingRemoteDesktop(a.id, into: nas.id)
        #expect(throws: VaultEditError.serviceExists("VNC")) { try once.mergingRemoteDesktop(b.id, into: nas.id) }
        #expect(throws: VaultEditError.unknownRemoteDesktop) { try once.mergingRemoteDesktop(UUID(), into: nas.id) }
        #expect(throws: VaultEditError.unknownServer) { try once.mergingRemoteDesktop(b.id, into: UUID()) }
    }

    @Test func serversMatchingAHostForTheAddQuestion() {
        let nas = Server(name: "nas", host: "nas.example.com", username: "admin")
        let other = Server(name: "o", host: "o.example.com", username: "admin")
        #expect(vault([nas, other]).servers(matchingHost: " NAS.example.com ").map(\.id) == [nas.id])
        #expect(vault([nas, other]).servers(matchingHost: "x.example.com").isEmpty)
    }

    // MARK: older and newer vaults

    @Test func oldVaultsLoadWithSSHOnAndStandaloneScreens() throws {
        let json = """
        {"version":1,"groups":[],"credentials":[],"knownHosts":[],
         "servers":[{"id":"6F0C2B1E-1111-4C47-9A5B-000000000001","name":"nas","host":"nas.example.com","port":22,"username":"admin"}],
         "remoteDesktops":[{"id":"6F0C2B1E-1111-4C47-9A5B-000000000002","name":"nas vnc","kind":"vnc","host":"localhost","port":5900,
                            "tunnelServerID":"6F0C2B1E-1111-4C47-9A5B-000000000001","transport":"sshShared","pointerMode":"trackpad"}]}
        """
        let vault = try JSONDecoder().decode(Vault.self, from: Data(json.utf8))
        #expect(vault.servers[0].sshEnabled)
        #expect(vault.remoteDesktops[0].serverID == nil && !vault.remoteDesktops[0].keepSeparate)
        #expect(vault.mergeSuggestions.count == 1)
    }

    @Test func newVaultsKeepEveryOldFieldForOlderBuilds() throws {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi", credentialID: pw.id)
        let next = try vault([box]).settingServices(of: box.id, ssh: false, screens: [.rdp])
        let data = try JSONEncoder().encode(next)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try #require((object["servers"] as? [[String: Any]])?.first)
        let screen = try #require((object["remoteDesktops"] as? [[String: Any]])?.first)
        #expect(server["ssh"] as? Bool == false)
        // An older build sees a full remote desktop entry (name, kind, host, port, login), so nothing is lost.
        for field in ["id", "name", "kind", "host", "port", "username", "credentialID", "transport"] {
            #expect(screen[field] != nil, "missing \(field)")
        }
        #expect(screen["serverID"] as? String == box.id.uuidString)
        // Written back by an older build (new keys dropped), it loads as a standalone screen and SSH on.
        var old = object
        old["servers"] = [server.filter { $0.key != "ssh" }]
        old["remoteDesktops"] = [screen.filter { $0.key != "serverID" }]
        let reloaded = try JSONDecoder().decode(Vault.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(reloaded.servers[0].sshEnabled && reloaded.remoteDesktops[0].serverID == nil)
        #expect(reloaded.remoteDesktops[0].credentialID == pw.id)
        // And round-trips unchanged in this build.
        #expect(try JSONDecoder().decode(Vault.self, from: data) == next)
        // SSH on writes no new key at all.
        let plain = try JSONEncoder().encode(Server(name: "a", host: "a.example.com", username: "u"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("\"ssh\""))
    }
}
