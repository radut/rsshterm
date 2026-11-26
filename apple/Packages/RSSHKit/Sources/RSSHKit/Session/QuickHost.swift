import Foundation

/// One host typed in Quick Connect: "host", "host:port", "user@host[:port]" or "[v6]:port". The user and port are
/// optional; the screen's username and port fill in the ones a host does not carry.
public struct QuickHost: Hashable, Sendable, Identifiable {
    public var username: String?
    public var host: String
    public var port: Int?

    public init(username: String? = nil, host: String, port: Int? = nil) {
        self.username = username
        self.host = host
        self.port = port
    }

    public var id: String { displayName }

    /// One token (no spaces); nil when it is not a host.
    public static func parse(_ token: String) -> QuickHost? {
        let text = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let user = parts.count == 2 ? String(parts[0]) : nil
        if let user, user.isEmpty { return nil }
        guard let (host, port) = QuickAddress.hostAndPort(parts[parts.count - 1]),
              !host.contains("/"), !host.contains(",") else { return nil }
        return QuickHost(username: user, host: host, port: port)
    }

    /// A pasted list: hosts separated by new lines, commas, semicolons or spaces. Duplicates are dropped; tokens that
    /// are not hosts come back in `invalid`, in order.
    public static func parseList(_ text: String) -> (hosts: [QuickHost], invalid: [String]) {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        var hosts: [QuickHost] = []
        var invalid: [String] = []
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            guard let host = parse(token) else { invalid.append(token); continue }
            if !hosts.contains(host) { hosts.append(host) }
        }
        return (hosts, invalid)
    }

    /// What the row shows: "user@host:port" with the parts the host carries.
    public var displayName: String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let withPort = port.map { "\(shownHost):\($0)" } ?? (host.contains(":") ? host : shownHost)
        return username.map { "\($0)@\(withPort)" } ?? withPort
    }

    /// The connection with `username` / `port` filling in what the host does not carry.
    public func target(username fallbackUser: String?, port fallbackPort: String) throws(ConnectionTarget.ValidationError)
        -> ConnectionTarget {
        try ConnectionTarget.validated(host: host, port: port.map(String.init) ?? fallbackPort,
                                       username: username ?? fallbackUser ?? "")
    }
}
