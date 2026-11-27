import Foundation
import Testing
@testable import RSSHDesktopCore

@Suite struct BroadcastTests {
    let shell = { Pane(content: .localShell()) }
    /// Window 1: tab A (p1 | p2), tab B (p3). Window 2: tab C (p4).
    func layout() -> (windows: [Window], p: [PaneID]) {
        let p1 = Pane(content: .localShell()), p2 = Pane(content: .localShell())
        let p3 = Pane(content: .localShell()), p4 = Pane(content: .localShell())
        let tabA = Tab(pane: p1).splitting(.right, with: p2)
        let w1 = Window(tabs: [tabA, Tab(pane: p3)])
        let w2 = Window(tabs: [Tab(pane: p4)])
        return ([w1, w2], [p1.id, p2.id, p3.id, p4.id])
    }

    @Test func currentOnlyByDefault() {
        let (windows, p) = layout()
        let state = BroadcastState()
        #expect(state.mode == .currentOnly)
        #expect(state.targets(for: p[0], windows: windows, visible: Set(p)) == [p[0]])
    }

    @Test func allTabsIsTheWindowsPanesAndTogglesOff() {
        let (windows, p) = layout()
        let on = BroadcastState().applying(.broadcastAllTabs, focused: p[0])
        #expect(on.mode == .allTabs)
        #expect(on.targets(for: p[1], windows: windows, visible: []) == [p[1], p[0], p[2]])
        #expect(on.applying(.broadcastAllTabs, focused: p[0]).mode == .currentOnly)
    }

    @Test func currentTabAndVisible() {
        let (windows, p) = layout()
        let tab = BroadcastState().applying(.broadcastCurrentTab, focused: p[0])
        #expect(tab.targets(for: p[0], windows: windows, visible: []) == [p[0], p[1]])
        #expect(tab.targets(for: p[2], windows: windows, visible: []) == [p[2]])
        let visible = BroadcastState().applying(.broadcastVisible, focused: p[0])
        #expect(visible.targets(for: p[0], windows: windows, visible: [p[0], p[1], p[3]]) == [p[0], p[1], p[3]])
    }

    @Test func manualSessionsAcrossTabs() {
        let (windows, p) = layout()
        var state = BroadcastState().applying(.toggleBroadcastSession, focused: p[0])
        state = state.applying(.toggleBroadcastSession, focused: p[3])
        #expect(state.mode == .manual)
        #expect(state.targets(for: p[0], windows: windows, visible: []) == [p[0], p[3]])
        // The source always gets its own input, receiving or not.
        #expect(state.targets(for: p[2], windows: windows, visible: []) == [p[2], p[0], p[3]])
        #expect(state.isReceiving(p[3], windows: windows, visible: []))
        // Badge click removes one; the last one removed returns to current only.
        state = state.removing(p[3])
        state = state.removing(p[0])
        #expect(state.mode == .currentOnly)
    }

    /// Every pane the input reaches is striped, the one typed in included (iTerm2, Termius); nothing when the input
    /// reaches one pane only.
    @Test func everyPaneInTheBroadcastIsStripedTheSourceIncluded() {
        let (windows, p) = layout()
        let tab = BroadcastState().applying(.broadcastCurrentTab, focused: p[0])
        #expect(tab.isReceiving(p[0], windows: windows, visible: [], focused: p[0]))
        #expect(tab.isReceiving(p[1], windows: windows, visible: [], focused: p[0]))
        #expect(!tab.isReceiving(p[2], windows: windows, visible: [], focused: p[0]))
        // Alone in its tab: one target, no stripes.
        #expect(!tab.isReceiving(p[2], windows: windows, visible: [], focused: p[2]))
        let all = BroadcastState().applying(.broadcastAllTabs, focused: p[0])
        #expect([p[0], p[1], p[2]].allSatisfy { all.isReceiving($0, windows: windows, visible: [], focused: p[1]) })
        #expect(!all.isReceiving(p[3], windows: windows, visible: [], focused: p[1]))
        #expect(!all.isReceiving(p[3], windows: windows, visible: [], focused: p[3])) // window 2 has one pane
        #expect(!BroadcastState().isReceiving(p[0], windows: windows, visible: Set(p), focused: p[0]))
    }

    @Test func manualAndVisibleStripeTheSourceEvenOutsideTheSet() {
        let (windows, p) = layout()
        let manual = BroadcastState().broadcasting(to: [p[1], p[3]])
        // Typing in p0 (not picked): the input goes to p0, p1, p3, so all three are striped.
        #expect([p[0], p[1], p[3]].allSatisfy { manual.isReceiving($0, windows: windows, visible: [], focused: p[0]) })
        #expect(!manual.isReceiving(p[2], windows: windows, visible: [], focused: p[0]))
        // One pane picked and typed in: it is the only target, no stripes.
        let one = BroadcastState().broadcasting(to: [p[1]])
        #expect(!one.isReceiving(p[1], windows: windows, visible: [], focused: p[1]))
        #expect(one.isReceiving(p[1], windows: windows, visible: [], focused: p[0]))
        let visible = BroadcastState().applying(.broadcastVisible, focused: p[0])
        #expect(visible.isReceiving(p[2], windows: windows, visible: [p[0], p[1]], focused: p[2]))
        #expect(visible.isReceiving(p[0], windows: windows, visible: [p[0], p[1]], focused: p[2]))
        #expect(!visible.isReceiving(p[3], windows: windows, visible: [p[0], p[1]], focused: p[2]))
    }

    /// The source pane's badge stops the broadcast; another pane's badge takes that pane out.
    @Test func theSourceBadgeStopsBroadcasting() {
        let (windows, p) = layout()
        let all = BroadcastState().applying(.broadcastAllTabs, focused: p[0])
        let reached = all.targets(for: p[0], windows: windows, visible: [])
        #expect(all.removing(p[0], reached: reached, source: p[0]) == BroadcastState())
        let without1 = all.removing(p[1], reached: reached, source: p[0])
        #expect(without1.mode == .manual && without1.manual == [p[0], p[2]])
    }

    @Test func closedPanesDropOut() {
        let (windows, p) = layout()
        let state = BroadcastState().applying(.toggleBroadcastSession, focused: p[0])
            .applying(.toggleBroadcastSession, focused: p[1])
        let pruned = state.pruned(existing: [p[1]])
        #expect(pruned.manual == [p[1]])
        // p0 closed: the layout no longer has it, so it gets nothing even before pruning.
        let afterClose = [Window(tabs: [Tab(pane: Pane(id: p[1], content: .localShell()))]), windows[1]]
        #expect(state.targets(for: p[1], windows: afterClose, visible: []) == [p[1]])
    }

    @Test func currentOnlyClearsTheManualSet() {
        let (_, p) = layout()
        let state = BroadcastState().applying(.toggleBroadcastSession, focused: p[0])
            .applying(.broadcastCurrentOnly, focused: p[0])
        #expect(state.mode == .currentOnly)
        #expect(state.manual.isEmpty)
    }

    @Test func keys() throws {
        let mac = Keybindings.defaults(for: .macOS), linux = Keybindings.defaults(for: .linux)
        #expect(mac.action(for: try KeyChord(parsing: "cmd+shift+i")) == .broadcastAllTabs)
        #expect(mac.action(for: try KeyChord(parsing: "cmd+alt+i")) == .broadcastCurrentTab)
        #expect(mac.action(for: try KeyChord(parsing: "cmd+alt+shift+i")) == .broadcastPicker)
        #expect(mac.chords(for: .broadcastCurrentOnly).isEmpty) // menu only; Cmd+Shift+I toggles off
        #expect(mac.action(for: try KeyChord(parsing: "cmd+ctrl+alt+shift+i")) == .toggleBroadcastSession)
        #expect(linux.action(for: try KeyChord(parsing: "ctrl+shift+i")) == .broadcastAllTabs)
        #expect(linux.action(for: try KeyChord(parsing: "ctrl+alt+shift+i")) == .broadcastPicker)
        #expect(DesktopAction(identifier: "toggleBroadcastInput") == .broadcastCurrentTab) // old config name
    }

    @Test func pickerPresets() {
        let (windows, p) = layout()
        let hosts = [p[0]: "web1.example.com", p[3]: "web1.example.com", p[2]: "db.example.com"]
        let group = UUID()
        let groups = [p[0]: group, p[2]: group]
        let presets = BroadcastPresets.presets(for: p[0], windows: windows, visible: [p[0], p[1], p[3]],
                                               hosts: hosts, groups: groups)
        let byName = Dictionary(presets.map { ($0.name, $0.panes) }) { a, _ in a }
        #expect(presets.map(\.name) == ["Panes in this tab", "All tabs of this window", "Visible panes", "All windows",
                                         "Same host as this pane", "Panes in the same server group"])
        #expect(byName["Panes in this tab"] == [p[0], p[1]])
        #expect(byName["All tabs of this window"] == [p[0], p[1], p[2]])
        #expect(byName["Visible panes"] == [p[0], p[1], p[3]])
        #expect(byName["All windows"] == p)
        #expect(byName["Same host as this pane"] == [p[0], p[3]])
        #expect(byName["Panes in the same server group"] == [p[0], p[2]])
        // A local pane has no host or group presets.
        #expect(BroadcastPresets.presets(for: p[1], windows: windows, visible: [], hosts: hosts, groups: groups)
            .map(\.name) == ["Panes in this tab", "All tabs of this window", "All windows"])
    }

    @Test func pickerStartsManualBroadcast() {
        let (windows, p) = layout()
        let state = BroadcastState().broadcasting(to: [p[1], p[3]])
        #expect(state.mode == .manual)
        #expect(state.targets(for: p[1], windows: windows, visible: []) == [p[1], p[3]])
        #expect(BroadcastState().broadcasting(to: []).mode == .currentOnly)
    }
}
