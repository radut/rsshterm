import Foundation

/// Where typed and pasted input goes (iTerm2's Broadcast Input).
public enum BroadcastMode: String, Codable, Sendable {
    /// Only the focused pane.
    case currentOnly
    /// Every pane in every tab of the focused pane's window.
    case allTabs
    /// Every pane of the focused pane's tab.
    case currentTab
    /// Every pane on screen, in all windows.
    case visible
    /// Panes picked by hand (any tabs, any windows).
    case manual
}

/// The broadcast mode and the hand-picked panes. Pure value: the app asks `targets(for:)` on each keystroke or paste
/// and stripes every pane in the broadcast from `isReceiving`.
public struct BroadcastState: Codable, Equatable, Sendable {
    public private(set) var mode: BroadcastMode
    public private(set) var manual: Set<PaneID>

    public init(mode: BroadcastMode = .currentOnly, manual: Set<PaneID> = []) {
        self.mode = mode
        self.manual = manual
    }

    /// A broadcast action. Choosing the mode that is on turns broadcasting off; toggling the session adds or removes
    /// the focused pane from the hand-picked set (empty set = off). Other actions change nothing.
    public func applying(_ action: DesktopAction, focused: PaneID) -> BroadcastState {
        func toggled(_ m: BroadcastMode) -> BroadcastState {
            mode == m ? BroadcastState() : BroadcastState(mode: m)
        }
        switch action {
        case .broadcastCurrentOnly: return BroadcastState()
        case .broadcastAllTabs: return toggled(.allTabs)
        case .broadcastCurrentTab: return toggled(.currentTab)
        case .broadcastVisible: return toggled(.visible)
        case .toggleBroadcastSession:
            var set = mode == .manual ? manual : []
            if set.contains(focused) { set.remove(focused) } else { set.insert(focused) }
            return broadcasting(to: set)
        default: return self
        }
    }

    /// Hand-picked broadcasting to `panes` (the picker's Enter); nothing picked is "current only".
    public func broadcasting(to panes: Set<PaneID>) -> BroadcastState {
        panes.isEmpty ? BroadcastState() : BroadcastState(mode: .manual, manual: panes)
    }

    /// Takes one pane out (its badge was clicked): a hand-picked set shrinks; other modes become a hand-picked set of
    /// what they reached minus that pane, so the click does what it says.
    public func removing(_ pane: PaneID, reached: [PaneID] = []) -> BroadcastState {
        switch mode {
        case .currentOnly: return self
        case .manual: return broadcasting(to: manual.subtracting([pane]))
        default: return broadcasting(to: Set(reached).subtracting([pane]))
        }
    }

    /// Without the panes that closed.
    public func pruned(existing: Set<PaneID>) -> BroadcastState {
        mode == .manual ? broadcasting(to: manual.intersection(existing)) : self
    }

    /// Where input typed in `source` goes: `source` first, then the other receiving panes in layout order (windows,
    /// tabs, split order), only panes that still exist.
    public func targets(for source: PaneID, windows: [Window], visible: Set<PaneID>) -> [PaneID] {
        let all = windows.flatMap { $0.tabs.flatMap(\.paneIDs) }
        let others: [PaneID]
        switch mode {
        case .currentOnly:
            others = []
        case .allTabs:
            others = windows.first { $0.tabs.contains { $0.root.contains(source) } }?.tabs.flatMap(\.paneIDs) ?? []
        case .currentTab:
            others = windows.flatMap(\.tabs).first { $0.root.contains(source) }?.paneIDs ?? []
        case .visible:
            others = all.filter(visible.contains)
        case .manual:
            others = all.filter(manual.contains)
        }
        guard all.contains(source) else { return [] }
        return [source] + others.filter { $0 != source }
    }

    /// Whether `pane` is in the broadcast: input typed in the focused pane reaches it, the focused pane itself
    /// included, and that input reaches more than one pane (the striped background and badge, as in iTerm2 and
    /// Termius). Current only, or a broadcast that reaches one pane: nothing. Without a focused pane, a hand-picked
    /// or visible set of two or more stands in for the reach.
    public func isReceiving(_ pane: PaneID, windows: [Window], visible: Set<PaneID>, focused: PaneID? = nil) -> Bool {
        if mode == .currentOnly { return false }
        guard let focused else {
            let all = windows.flatMap { $0.tabs.flatMap(\.paneIDs) }
            let set: [PaneID] = switch mode {
            case .manual: all.filter(manual.contains)
            case .visible: all.filter(visible.contains)
            default: []
            }
            return set.count > 1 && set.contains(pane)
        }
        let reach = targets(for: focused, windows: windows, visible: visible)
        return reach.count > 1 && reach.contains(pane)
    }

    /// A badge click on `pane`: on the `source` pane (the one typed in) it stops broadcasting, elsewhere it takes
    /// that pane out (`removing(_:reached:)`).
    public func removing(_ pane: PaneID, reached: [PaneID], source: PaneID?) -> BroadcastState {
        pane == source ? BroadcastState() : removing(pane, reached: reached)
    }
}

/// A ready-made set of panes in the broadcast picker.
public struct BroadcastPreset: Equatable, Sendable {
    public let name: String
    public let panes: [PaneID]
}

public enum BroadcastPresets {
    /// The picker's presets for the focused pane `source`: its tab, its window's tabs, the visible panes, all
    /// windows, the panes on the same host and in the same server group (`hosts`/`groups`: SSH panes only). Presets
    /// that would be empty, or that do not apply (a local pane has no host), are left out. Panes in layout order.
    public static func presets(for source: PaneID, windows: [Window], visible: Set<PaneID>,
                               hosts: [PaneID: String], groups: [PaneID: UUID]) -> [BroadcastPreset] {
        let all = windows.flatMap { $0.tabs.flatMap(\.paneIDs) }
        var out: [BroadcastPreset] = []
        func add(_ name: String, _ panes: [PaneID]) { if !panes.isEmpty { out.append(BroadcastPreset(name: name, panes: panes)) } }
        add("Panes in this tab", windows.flatMap(\.tabs).first { $0.root.contains(source) }?.paneIDs ?? [])
        add("All tabs of this window",
            windows.first { $0.tabs.contains { $0.root.contains(source) } }?.tabs.flatMap(\.paneIDs) ?? [])
        add("Visible panes", all.filter(visible.contains))
        add("All windows", all)
        if let host = hosts[source]?.lowercased() {
            add("Same host as this pane", all.filter { hosts[$0]?.lowercased() == host })
        }
        if let group = groups[source] {
            add("Panes in the same server group", all.filter { groups[$0] == group })
        }
        return out
    }
}
