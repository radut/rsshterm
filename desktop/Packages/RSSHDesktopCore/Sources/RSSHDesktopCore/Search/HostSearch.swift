import Foundation
import RSSHKit

/// One server found by the host search menu (Cmd/Ctrl+Shift+O/K): its score and the field the query matched best.
public struct HostSearchResult: Equatable, Sendable {
    public enum Field: String, Sendable { case name, host, user, group }

    public let server: Server
    public let groupName: String?
    public let score: Int
    public let matchedField: Field

    /// A new tab with an SSH session to this server.
    public func openTab() -> Tab {
        Tab(pane: Pane(content: .ssh(serverID: server.id)))
    }
}

/// The vault's servers and groups, searched by name, host, user and group name. The vault has no tags yet; when it
/// gets them they join `fields` here.
public struct HostSearchIndex: Sendable {
    public let servers: [Server]
    private let groupNames: [UUID: String]

    public init(servers: [Server], groups: [ServerGroup]) {
        self.servers = servers
        self.groupNames = Dictionary(groups.map { ($0.id, $0.name) }) { first, _ in first }
    }

    /// Weights: the name counts most, then host, then user and group.
    private static let weights: [HostSearchResult.Field: Int] = [.name: 4, .host: 3, .user: 2, .group: 2]

    /// Ranked results. Every whitespace-separated word must match some field; `user@host` matches user and host.
    /// An empty query lists every server by name.
    public func search(_ query: String, limit: Int = 50) -> [HostSearchResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let results: [HostSearchResult] = servers.compactMap { server in
            let group = server.groupID.flatMap { groupNames[$0] }
            guard !words.isEmpty else {
                return HostSearchResult(server: server, groupName: group, score: 0, matchedField: .name)
            }
            let fields = fields(of: server, group: group)
            var total = 0
            var best: (HostSearchResult.Field, Int)?
            for word in words {
                guard let (field, score) = bestMatch(word, fields: fields) else { return nil }
                total += score
                if best == nil || score > best!.1 { best = (field, score) }
            }
            return HostSearchResult(server: server, groupName: group, score: total, matchedField: best!.0)
        }
        let sorted = results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let order = $0.server.name.localizedCaseInsensitiveCompare($1.server.name)
            return order == .orderedSame ? $0.server.id.uuidString < $1.server.id.uuidString : order == .orderedAscending
        }
        return Array(sorted.prefix(max(limit, 0)))
    }

    private func fields(of server: Server, group: String?) -> [(HostSearchResult.Field, String)] {
        var fields: [(HostSearchResult.Field, String)] = [(.name, server.name), (.host, server.host),
                                                           (.user, server.username)]
        if let group { fields.append((.group, group)) }
        return fields
    }

    private func bestMatch(_ word: String, fields: [(HostSearchResult.Field, String)]) -> (HostSearchResult.Field, Int)? {
        if let at = word.firstIndex(of: "@"), at != word.startIndex {
            let user = String(word[..<at]), host = String(word[word.index(after: at)...])
            let text = fields.first { $0.0 == .user }?.1 ?? ""
            guard let u = FuzzyMatcher.score(user, in: text) else { return nil }
            let hosts = fields.filter { $0.0 == .host || $0.0 == .name }
            guard let h = hosts.compactMap({ field in FuzzyMatcher.score(host, in: field.1).map { (field.0, $0) } })
                .max(by: { $0.1 < $1.1 }) else { return nil }
            return (h.0, (u + h.1) * Self.weights[.host]!)
        }
        return fields.compactMap { field, text in
            FuzzyMatcher.score(word, in: text).map { (field, $0 * Self.weights[field]!) }
        }.max { $0.1 < $1.1 }
    }
}
