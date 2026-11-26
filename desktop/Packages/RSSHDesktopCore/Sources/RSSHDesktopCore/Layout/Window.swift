import Foundation

/// One desktop window: its tabs (never empty), the selected one, and whether typing goes to every pane of the
/// selected tab (broadcast input). Every edit returns a new value; an edit that leaves no tab returns nil (the
/// window closes).
public struct Window: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let tabs: [Tab]
    public let selectedIndex: Int
    public let broadcastsInput: Bool

    /// `tabs` must not be empty.
    public init(id: UUID = UUID(), tabs: [Tab], selectedIndex: Int = 0, broadcastsInput: Bool = false) {
        precondition(!tabs.isEmpty, "a window has at least one tab")
        self.id = id
        self.tabs = tabs
        self.selectedIndex = min(max(selectedIndex, 0), tabs.count - 1)
        self.broadcastsInput = broadcastsInput
    }

    private func with(tabs: [Tab]? = nil, selectedIndex: Int? = nil, broadcastsInput: Bool? = nil) -> Window {
        Window(id: id, tabs: tabs ?? self.tabs, selectedIndex: selectedIndex ?? self.selectedIndex,
               broadcastsInput: broadcastsInput ?? self.broadcastsInput)
    }

    public var selectedTab: Tab { tabs[selectedIndex] }

    /// Opens `tab` right after the selected one and selects it.
    public func addingTab(_ tab: Tab) -> Window {
        var newTabs = tabs
        newTabs.insert(tab, at: selectedIndex + 1)
        return with(tabs: newTabs, selectedIndex: selectedIndex + 1)
    }

    /// Cmd/Ctrl+1…8 select that tab, 9 the last one; a number with no tab changes nothing.
    public func selectingTab(number: Int) -> Window {
        switch number {
        case 9: return with(selectedIndex: tabs.count - 1)
        case 1...8 where number <= tabs.count: return with(selectedIndex: number - 1)
        default: return self
        }
    }

    public func selectingNextTab() -> Window { with(selectedIndex: (selectedIndex + 1) % tabs.count) }
    public func selectingPreviousTab() -> Window { with(selectedIndex: (selectedIndex + tabs.count - 1) % tabs.count) }

    public func movingTab(from source: Int, to destination: Int) -> Window {
        guard tabs.indices.contains(source), tabs.indices.contains(destination) else { return self }
        var newTabs = tabs
        let moved = newTabs.remove(at: source)
        newTabs.insert(moved, at: destination)
        let selectedID = selectedTab.id
        return with(tabs: newTabs, selectedIndex: newTabs.firstIndex { $0.id == selectedID } ?? 0)
    }

    /// Closes tab `index`; the tab that takes its place (or its left neighbour, for the last) is selected.
    public func closingTab(at index: Int) -> Window? {
        guard tabs.indices.contains(index) else { return self }
        var newTabs = tabs
        newTabs.remove(at: index)
        guard !newTabs.isEmpty else { return nil }
        let newSelection = index < selectedIndex ? selectedIndex - 1 : min(selectedIndex, newTabs.count - 1)
        return with(tabs: newTabs, selectedIndex: newSelection)
    }

    /// Applies `edit` to the selected tab.
    public func updatingSelectedTab(_ edit: (Tab) -> Tab) -> Window {
        var newTabs = tabs
        newTabs[selectedIndex] = edit(selectedTab)
        return with(tabs: newTabs)
    }

    /// Closes the focused pane of the selected tab, the tab with its last pane, the window with its last tab.
    public func closingFocusedPane() -> Window? {
        guard let tab = selectedTab.closing(selectedTab.focused) else { return closingTab(at: selectedIndex) }
        return updatingSelectedTab { _ in tab }
    }

    public func togglingBroadcast() -> Window { with(broadcastsInput: !broadcastsInput) }
}

extension Window {
    private enum CodingKeys: String, CodingKey { case id, tabs, selectedIndex, broadcastsInput }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tabs = try c.decode([Tab].self, forKey: .tabs)
        guard !tabs.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .tabs, in: c, debugDescription: "a window without tabs")
        }
        self.init(id: try c.decode(UUID.self, forKey: .id), tabs: tabs,
                  selectedIndex: try c.decodeIfPresent(Int.self, forKey: .selectedIndex) ?? 0,
                  broadcastsInput: try c.decodeIfPresent(Bool.self, forKey: .broadcastsInput) ?? false)
    }
}

/// Everything restored at the next launch: the windows, in order.
public struct Session: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let windows: [Window]

    public init(windows: [Window]) {
        self.version = Self.currentVersion
        self.windows = windows
    }
}
