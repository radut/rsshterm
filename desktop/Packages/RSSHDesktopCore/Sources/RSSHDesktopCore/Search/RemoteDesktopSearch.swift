import Foundation
import RSSHKit

/// Remote desktops for host search (Cmd/Ctrl+K) and the jump switcher: fuzzy over name, kind, host, folder and the
/// server it goes through; every word must match some field. An empty query lists them all by name.
public enum RemoteDesktopSearch {
    public static func search(_ query: String, desktops: [RemoteDesktop], groups: [ServerGroup], servers: [Server],
                              limit: Int = 50) -> [RemoteDesktop] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let groupNames = Dictionary(groups.map { ($0.id, $0.name) }) { a, _ in a }
        let serverNames = Dictionary(servers.map { ($0.id, $0.name) }) { a, _ in a }
        let scored: [(RemoteDesktop, Int)] = desktops.compactMap { d in
            let fields = [d.name, d.kind.title, d.kind.rawValue, d.host,
                          d.groupID.flatMap { groupNames[$0] } ?? "", d.tunnelServerID.flatMap { serverNames[$0] } ?? ""]
                .filter { !$0.isEmpty }
            var total = 0
            for word in words {
                guard let best = fields.compactMap({ FuzzyMatcher.score(word, in: $0) }).max() else { return nil }
                total += best
            }
            return (d, total)
        }
        return Array(scored.sorted {
            $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        }.map(\.0).prefix(max(limit, 0)))
    }
}
