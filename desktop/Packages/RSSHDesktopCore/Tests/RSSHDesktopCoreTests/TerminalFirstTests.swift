import Foundation
import Testing
@testable import RSSHDesktopCore

/// The desktop app opens as a terminal: launch, new tabs and opened servers (docs/desktop/terminal-first.md).
@Suite struct TerminalFirstTests {
    private let server = UUID()

    private func window(_ contents: PaneContent...) -> Window {
        Window(tabs: contents.map { Tab(pane: Pane(content: $0)) })
    }

    // MARK: Launch

    @Test func freshLaunchOpensOneLocalShell() {
        let plan = LaunchPlan.make(restoreSession: true, saved: nil)
        #expect(plan == .localShell)
        #expect(plan.windows.count == 1)
        #expect(plan.windows[0].tabs.count == 1)
        #expect(plan.windows[0].selectedTab.focusedPane.content == .localShell())
    }

    @Test func aLocalShellNeverWaitsForTheVault() {
        #expect(!LaunchPlan.localShell.needsVault)
        #expect(!LaunchPlan.make(restoreSession: true, saved: Session(windows: [window(.localShell(directory: "/tmp"))])).needsVault)
    }

    @Test func restoreWindowsOnReopensTheSavedWindows() {
        let saved = Session(windows: [window(.localShell()), window(.ssh(serverID: server), .localShell())])
        let plan = LaunchPlan.make(restoreSession: true, saved: saved)
        #expect(plan == .restore(saved.windows))
        #expect(plan.windows == saved.windows)
    }

    @Test func restoreWindowsOffIgnoresTheSavedWindows() {
        let saved = Session(windows: [window(.ssh(serverID: server))])
        #expect(LaunchPlan.make(restoreSession: false, saved: saved) == .localShell)
    }

    @Test func nothingSavedGivesALocalShell() {
        #expect(LaunchPlan.make(restoreSession: true, saved: Session(windows: [])) == .localShell)
    }

    @Test func onlyRestoredServersAskForTheVault() {
        let withServer = LaunchPlan.make(restoreSession: true, saved: Session(windows: [window(.localShell(), .ssh(serverID: server))]))
        #expect(withServer.needsVault)
        let withScreen = LaunchPlan.make(restoreSession: true, saved: Session(windows: [window(.remoteDesktop(id: server))]))
        #expect(withScreen.needsVault)
    }

    // MARK: New tabs and opened servers

    @Test func newTabGoesToTheFrontmostTerminalWindow() {
        #expect(TerminalRouting.target(for: .newLocalTab, frontToBack: ["b", "a"]) == .tab(in: "b"))
        #expect(TerminalRouting.content(of: .newLocalTab) == .localShell())
    }

    @Test func newTabWithNoTerminalWindowOpensAWindow() {
        #expect(TerminalRouting.target(for: .newLocalTab, frontToBack: [String]()) == .newWindow)
    }

    @Test func newWindowIsAlwaysANewWindowWithALocalShell() {
        #expect(TerminalRouting.target(for: .newLocalWindow, frontToBack: ["a"]) == .newWindow)
        #expect(TerminalRouting.content(of: .newLocalWindow) == .localShell())
    }

    @Test func aServerOpensAsATabOfTheFrontmostWindowOrANewWindow() {
        let request = TerminalRequest.open(.ssh(serverID: server))
        #expect(TerminalRouting.target(for: request, frontToBack: [2, 1]) == .tab(in: 2))
        #expect(TerminalRouting.target(for: request, frontToBack: [Int]()) == .newWindow)
        #expect(TerminalRouting.content(of: request) == .ssh(serverID: server))
    }

    @Test func newTabAndNewWindowKeysMakeRequests() {
        #expect(TerminalRouting.request(for: .newTab) == .newLocalTab)
        #expect(TerminalRouting.request(for: .newWindow) == .newLocalWindow)
        #expect(TerminalRouting.request(for: .splitRight) == nil)
    }

    @Test func theDefaultKeysAreTheTerminalOnes() throws {
        let mac = Keybindings.defaults(for: .macOS)
        #expect(mac.action(for: try KeyChord(parsing: "cmd+t")) == .newTab)
        #expect(mac.action(for: try KeyChord(parsing: "cmd+n")) == .newWindow)
        #expect(mac.action(for: try KeyChord(parsing: "cmd+shift+s")) == .showServers)
        let linux = Keybindings.defaults(for: .linux)
        #expect(linux.action(for: try KeyChord(parsing: "ctrl+shift+t")) == .newTab)
        #expect(linux.action(for: try KeyChord(parsing: "ctrl+shift+n")) == .newWindow)
    }

    // MARK: Last window

    @Test func theMacKeepsRunningAfterTheLastWindow() {
        #expect(!AppLifecycle.quitsAfterLastTerminalWindow(platform: .macOS, serversWindowOpen: false))
        #expect(!AppLifecycle.quitsAfterLastTerminalWindow(platform: .macOS, serversWindowOpen: true))
    }

    @Test func linuxQuitsAfterTheLastWindowUnlessServersIsOpen() {
        #expect(AppLifecycle.quitsAfterLastTerminalWindow(platform: .linux, serversWindowOpen: false))
        #expect(!AppLifecycle.quitsAfterLastTerminalWindow(platform: .linux, serversWindowOpen: true))
    }

    @Test func theDockIconOpensATerminalWhenNoneIsOpen() {
        #expect(AppLifecycle.reopenOpensTerminal(terminalWindows: 0))
        #expect(!AppLifecycle.reopenOpensTerminal(terminalWindows: 2))
    }
}
