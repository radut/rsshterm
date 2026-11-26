import Foundation
import Testing
@testable import RSSHKit

@Suite struct ScreenSharingServiceTests {
    let mac = Server(name: "studio", host: "studio.example.com", username: "anna")

    @Test func screenSharingIsItsOwnService() {
        #expect(ScreenService.allCases == [.rdp, .vnc, .screenSharing])
        #expect(ScreenService(.appleScreenSharing) == .screenSharing)
        #expect(ScreenService(.vnc) == .vnc)
        #expect(ScreenService.screenSharing.defaultKind == .appleScreenSharing)
        #expect(ScreenService.screenSharing.title == "Apple Screen Sharing")
        #expect(ScreenService.screenSharing.shortTitle == "Screen Sharing")
        #expect(ScreenService.vnc.title == "VNC")
    }

    @Test func rfbGreetingTellsAMacFromVNC() {
        #expect(ScreenService(port: 5900, rfbVersion: "RFB 003.889") == .screenSharing)
        #expect(ScreenService(port: 5900, rfbVersion: "RFB 003.889\n") == .screenSharing)
        #expect(ScreenService(port: 5900, rfbVersion: "RFB 003.008") == .vnc)
        #expect(ScreenService(port: 5901, rfbVersion: nil) == .vnc)
        #expect(ScreenService(port: 3389, rfbVersion: "RFB 003.889") == .rdp)
        #expect(ScreenService(port: 22, rfbVersion: "RFB 003.889") == nil)
        #expect(NetworkScanner.rfbGreeting("RFB 003.889\n") == "RFB 003.889")
        #expect(NetworkScanner.rfbGreeting("SSH-2.0-OpenSSH_9.6") == nil)
    }

    @Test func scanResultsNameAndAddScreenSharing() throws {
        let found = DiscoveredHost(host: "192.0.2.7", port: 5900, answered: [.ssh], rfbVersion: "RFB 003.889")
        #expect(found.screenService == .screenSharing)
        #expect(found.serviceTitle == "Apple Screen Sharing")
        let vnc = DiscoveredHost(host: "192.0.2.8", port: 5900, answered: [.ssh], rfbVersion: "RFB 003.008")
        let result = try Vault().addingDiscovered([found, vnc], to: .ungrouped, username: "anna")
        let macServer = try #require(result.added.first { $0.host == "192.0.2.7" })
        let screen = try #require(result.vault.service(.screenSharing, of: macServer.id))
        #expect(screen.kind == .appleScreenSharing && screen.username == "anna")
        let pi = try #require(result.added.first { $0.host == "192.0.2.8" })
        #expect(result.vault.service(.vnc, of: pi.id)?.username == nil)
    }

    @Test func mergedScanResultsKeepTheGreeting() {
        let tcp = DiscoveredHost(host: "192.0.2.7", port: 5900, answered: [.tcp])
        let probed = DiscoveredHost(host: "192.0.2.7", port: 5900, answered: [.ssh], rfbVersion: "RFB 003.889")
        #expect(tcp.merged(with: probed).screenService == .screenSharing)
    }

    @Test func aServerCanHaveVNCAndScreenSharing() throws {
        let saved = try Vault().addingServer(mac, screens: [.vnc, .screenSharing], screensJoinSavedServers: false).vault
        #expect(saved.services(of: mac.id).map { ScreenService($0.kind) } == [.vnc, .screenSharing])
        let sharing = try #require(saved.service(.screenSharing, of: mac.id))
        #expect(sharing.username == "anna" && sharing.port == 5900 && sharing.transport == .sshShared)
        #expect(saved.service(.vnc, of: mac.id)?.username == nil)
        let off = try saved.settingServices(of: mac.id, ssh: true, screens: [.screenSharing])
        #expect(off.service(.vnc, of: mac.id) == nil && off.service(.screenSharing, of: mac.id)?.id == sharing.id)
    }

    /// Vaults written by older builds: a VNC screen with Apple authentication is kind `appleScreenSharing`; it reads
    /// as the Screen Sharing service, and is written back as the same kind older builds read.
    @Test func olderVaultScreenSharingReadsAsItsOwnServiceAndRoundTrips() throws {
        let id = UUID(), serverID = UUID()
        let json = """
        {"id":"\(id)","name":"studio","kind":"appleScreenSharing","host":"localhost","port":5900,"username":"anna",
         "transport":"sshShared","tunnelServerID":"\(serverID)","serverID":"\(serverID)","pointerMode":"trackpad"}
        """
        let desktop = try JSONDecoder().decode(RemoteDesktop.self, from: Data(json.utf8))
        #expect(ScreenService(desktop.kind) == .screenSharing)
        let again = String(decoding: try JSONEncoder().encode(desktop), as: UTF8.self)
        #expect(again.contains("\"kind\":\"appleScreenSharing\""))
    }

    @Test func howToConnectListsEachService() throws {
        let saved = try Vault().addingServer(mac, screens: [.rdp, .screenSharing], screensJoinSavedServers: false).vault
        let choices = saved.connectChoices(for: mac)
        #expect(choices.map(\.service) == [.ssh, .rdp, .screenSharing])
        #expect(choices[0].opening == .ssh && choices[0].screenID == nil)
        #expect(choices[2].opening == .screen(try #require(saved.service(.screenSharing, of: mac.id)).id))
        #expect(saved.asksHowToConnect(mac))
        let plain = Server(name: "web", host: "web.example.com", username: "deploy")
        let one = try saved.addingServer(plain)
        #expect(one.connectChoices(for: plain).map(\.service) == [.ssh] && !one.asksHowToConnect(plain))
    }

    @Test func connectButtonsUseGenericGlyphs() {
        #expect(ConnectService.allCases.map(\.label) == ["SSH", "RDP", "VNC", "Screen Sharing"])
        #expect(ConnectService.allCases.map(\.symbolName) == ["terminal", "display", "rectangle.on.rectangle", "macwindow"])
        #expect(ConnectService.screenSharing.iconName == "rssh-connect-screenSharing-symbolic")
        #expect(ConnectService(.screenSharing).screen == .screenSharing && ConnectService.ssh.screen == nil)
    }
}
