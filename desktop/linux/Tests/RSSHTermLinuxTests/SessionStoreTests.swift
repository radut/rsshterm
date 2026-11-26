import Foundation
import RSSHDesktopCore
import Testing
@testable import RSSHTermLinux

@Suite struct SessionStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)/session.json")
    }

    private func sample() -> Window {
        let local = Pane(content: .localShell())
        let ssh = Pane(content: .ssh(serverID: UUID()))
        var w = Window(tabs: [Tab(pane: local)])
        w = w.updatingSelectedTab { $0.splitting(.right, with: ssh).renamed("prod") }
        return w.addingTab(Tab(pane: Pane(content: .localShell(command: ["htop"], directory: "/var"))))
    }

    @Test func captureRecordsLocalWorkingDirectories() throws {
        let w = sample()
        let local = w.tabs[0].panes[0]
        let session = SessionSnapshot.capture(windows: [w], directories: [local.id: "/tmp/work"])
        let restored = session.windows[0]
        #expect(restored.tabs[0].panes[0].content == .localShell(command: nil, directory: "/tmp/work"))
        #expect(restored.tabs[0].panes[1].content == w.tabs[0].panes[1].content) // ssh unchanged
        #expect(restored.tabs[1].panes[0].content == .localShell(command: ["htop"], directory: "/var"))
        #expect(restored.tabs[0].title == "prod")
        #expect(restored.tabs[0].root.frames().count == 2)
        #expect(restored.selectedIndex == w.selectedIndex)
    }

    @Test func saveLoadRoundTripOwnerOnly() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = Session(windows: [sample(), sample()])
        try SessionStore.save(session, to: url)
        #expect(SessionStore.load(from: url) == session)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func missingBrokenOrEmptyIsNil() throws {
        let url = tempURL()
        #expect(SessionStore.load(from: url) == nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{\"version\":1,\"windows\":[{\"tabs\":[]}]}".utf8).write(to: url)
        #expect(SessionStore.load(from: url) == nil)
        try SessionStore.save(Session(windows: []), to: url)
        #expect(SessionStore.load(from: url) == nil)
    }

    @Test func newerVersionIsIgnored() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{\"version\":99,\"windows\":[]}".utf8).write(to: url)
        #expect(SessionStore.load(from: url) == nil)
    }

    @Test func defaultPathFollowsXDGState() {
        #expect(SessionStore.defaultURL(environment: ["XDG_STATE_HOME": "/s"], home: "/h").path == "/s/rssh/session.json")
        #expect(SessionStore.defaultURL(environment: [:], home: "/h").path == "/h/.local/state/rssh/session.json")
    }

    @Test func restoreSettingDefaultsOn() throws {
        #expect(AppSettings().restoreSession)
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"restoreSession":false}"#.utf8))
        #expect(!s.restoreSession)
    }
}
