import Foundation
import RSSHDesktopCore
import RSSHKit

/// The host search popup (Ctrl+Shift+K): the query, its ranked results (core fuzzy search) and the highlighted row.
/// Enter opens the server in a new tab, Shift+Enter in a split of the focused pane.
public struct HostSearchModel: Sendable {
    public enum Choice: Equatable, Sendable {
        case openTab(UUID)
        case openSplit(UUID)
    }

    private let index: HostSearchIndex
    public let query: String
    public let results: [HostSearchResult]
    public let selection: Int

    public init(servers: [Server], groups: [ServerGroup]) {
        self.init(index: HostSearchIndex(servers: servers, groups: groups), query: "")
    }

    private init(index: HostSearchIndex, query: String, selection: Int = 0) {
        self.index = index
        self.query = query
        self.results = index.search(query)
        self.selection = results.isEmpty ? 0 : min(max(selection, 0), results.count - 1)
    }

    public func searching(_ text: String) -> HostSearchModel { HostSearchModel(index: index, query: text) }

    /// Moves the highlight, wrapping at both ends.
    public func moving(by step: Int) -> HostSearchModel {
        guard !results.isEmpty else { return self }
        let n = results.count
        return HostSearchModel(index: index, query: query, selection: ((selection + step) % n + n) % n)
    }

    public func choose(split: Bool) -> Choice? {
        guard results.indices.contains(selection) else { return nil }
        let id = results[selection].server.id
        return split ? .openSplit(id) : .openTab(id)
    }

    /// `user@host`, with `:port` when it is not 22.
    public static func subtitle(_ result: HostSearchResult) -> String {
        let s = result.server
        let base = "\(s.username)@\(s.host)"
        return s.port == 22 ? base : "\(base):\(s.port)"
    }
}
