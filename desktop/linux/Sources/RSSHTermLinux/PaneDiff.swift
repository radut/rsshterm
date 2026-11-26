import RSSHDesktopCore

/// Which terminals a layout change creates and which it ends: the UI spawns `added` and closes `removed`; panes in
/// both windows keep their running process, wherever they moved.
public struct PaneDiff: Equatable, Sendable {
    public let added: [Pane]
    public let removed: [PaneID]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    public init(from old: Window?, to new: Window?) {
        let before = old.map { $0.tabs.flatMap(\.panes) } ?? []
        let after = new.map { $0.tabs.flatMap(\.panes) } ?? []
        let beforeIDs = Set(before.map(\.id))
        let afterIDs = Set(after.map(\.id))
        added = after.filter { !beforeIDs.contains($0.id) }
        removed = before.map(\.id).filter { !afterIDs.contains($0) }
    }
}
