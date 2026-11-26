import Foundation
import Testing
@testable import RSSHKit

@Suite struct ScreenGapsTests {
    // MARK: scan finds screens without typing ports

    @Test func scansSSHRDPAndVNCByDefault() throws {
        #expect(ScanPorts.defaultText == "22 3389 5900")
        #expect(try ScanPorts.parse(ScanPorts.defaultText) == [22, 3389, 5900])
    }

    @Test func eachResultSaysWhatAnswered() {
        #expect(DiscoveredHost(host: "192.0.2.1").serviceTitle == "SSH")
        #expect(DiscoveredHost(host: "192.0.2.1", port: 3389, answered: [.tcp]).serviceTitle == "Remote Desktop (RDP)")
        #expect(DiscoveredHost(host: "192.0.2.1", port: 5900, answered: [.tcp]).serviceTitle == "VNC")
        #expect(DiscoveredHost(host: "192.0.2.1", port: 8080, answered: [.tcp]).serviceTitle == "port 8080")
        #expect(DiscoveredHost(host: "192.0.2.1", answered: [.ping]).serviceTitle == "ping only")
        #expect(DiscoveredHost(host: "192.0.2.1", port: 5900, answered: [.tcp]).isScreen)
        #expect(!DiscoveredHost(host: "192.0.2.1").isScreen)
    }

    // MARK: Quick Connect save with screens

    @Test func quickSaveAddsTheServerWithItsScreens() throws {
        let server = Server(name: "win", host: "win.example.com", username: "admin")
        let saved = try Vault().addingServer(server, screens: [.rdp], screensJoinSavedServers: false)
        #expect(saved.added == server && saved.vault.service(.rdp, of: server.id) != nil)
        var off = Server(name: "box", host: "box.example.com", username: "pi")
        off.sshEnabled = false
        #expect(throws: VaultEditError.noService) { try Vault().addingServer(off, screens: [], screensJoinSavedServers: false) }
    }

    @Test func quickSaveScreensJoinASavedHostOnlyWhenAsked() throws {
        let nas = Server(name: "nas", host: "nas.example.com", username: "admin")
        let start = Vault(servers: [nas])
        let typed = Server(name: "nas.example.com", host: "NAS.example.com", username: "admin")
        let joined = try start.addingServer(typed, screens: [.vnc], screensJoinSavedServers: true)
        #expect(joined.added == nil && joined.vault.servers == [nas] && joined.vault.service(.vnc, of: nas.id) != nil)
        let separate = try start.addingServer(typed, screens: [.vnc], screensJoinSavedServers: false)
        #expect(separate.added == typed && separate.vault.servers.count == 2)
        #expect(separate.vault.service(.vnc, of: nas.id) == nil)
    }

    // MARK: SSH off never silently breaks a tunnel

    @Test func screensThatNeedTheServersSSHAreListedAndCanGoDirect() throws {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi")
        let lab = RemoteDesktop(name: "lab", kind: .vnc, host: "198.51.100.9", tunnelServerID: box.id)
        let open = RemoteDesktop(name: "kiosk", kind: .vnc, host: "192.0.2.9")
        let start = try Vault(servers: [box], remoteDesktops: [lab, open]).settingServices(of: box.id, ssh: true, screens: [.rdp])
        let own = try #require(start.service(.rdp, of: box.id))
        #expect(Set(start.screensRelyingOnSSH(of: box.id).map(\.id)) == [own.id, lab.id])

        let direct = try start.switchingScreensToDirect(of: box.id)
        #expect(direct.screensRelyingOnSSH(of: box.id).isEmpty)
        let rdp = try #require(direct.service(.rdp, of: box.id))
        #expect(rdp.transport == .direct && rdp.tunnelServerID == nil && rdp.host == "192.0.2.5")
        let moved = try #require(direct.remoteDesktops.first { $0.id == lab.id })
        #expect(moved.transport == .direct && moved.host == "198.51.100.9")
        #expect(direct.remoteDesktops.first { $0.id == open.id } == open)

        // Kept through SSH: turning SSH off leaves them exactly as they were.
        let kept = try start.settingServices(of: box.id, ssh: false, screens: [.rdp])
        #expect(kept.service(.rdp, of: box.id) == own)
    }
}
