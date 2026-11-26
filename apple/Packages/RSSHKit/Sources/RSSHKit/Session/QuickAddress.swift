import Foundation

/// "user@host[:port]" typed in the server search box: enough to connect without a saved server.
public struct QuickAddress: Hashable, Sendable {
    public var username: String
    public var host: String
    /// nil when the text gave none (22 is used).
    public var port: Int?

    public init(username: String, host: String, port: Int?) {
        self.username = username
        self.host = host
        self.port = port
    }

    /// Accepts "user@host", "user@host:port", "user@[v6]:port" and the same after "ssh ". nil for anything else.
    public static func parse(_ text: String) -> QuickAddress? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.lowercased().hasPrefix("ssh ") {
            rest = String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        guard !rest.contains(where: \.isWhitespace) else { return nil }
        let parts = rest.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let (host, port) = hostAndPort(parts[1]) else { return nil }
        return QuickAddress(username: String(parts[0]), host: host, port: port)
    }

    /// "user@host", with ":port" when one was given and it is not 22.
    public var displayName: String { target.displayName }

    public var target: ConnectionTarget { ConnectionTarget(host: host, port: port ?? 22, username: username) }

    /// True for a saved server with the same user, host (case ignored) and port.
    public func matches(_ server: Server) -> Bool {
        server.username == username && server.host.lowercased() == host.lowercased() && server.port == (port ?? 22)
    }

    /// The editor's fields for saving this address as a server that logs in with `credentialID`.
    public func serverDraft(credentialID: UUID?) -> ServerDraft {
        ServerDraft(name: host, host: host, port: String(port ?? 22), username: username, credentialID: credentialID)
    }

    // MARK: parsing

    static func hostAndPort(_ text: Substring) -> (String, Int?)? {
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = text[text.index(after: text.startIndex)..<close]
            let tail = text[text.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if tail.isEmpty { return (String(host), nil) }
            guard tail.hasPrefix(":"), let port = port(tail.dropFirst()) else { return nil }
            return (String(host), port)
        }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        switch pieces.count {
        case 1:
            return text.isEmpty ? nil : (String(text), nil)
        case 2:
            guard !pieces[0].isEmpty, let port = port(pieces[1]) else { return nil }
            return (String(pieces[0]), port)
        default:
            // A bare IPv6 address: no port can be told apart from it.
            return (String(text), nil)
        }
    }

    private static func port(_ text: Substring) -> Int? {
        guard let value = Int(text), (1...65535).contains(value) else { return nil }
        return value
    }
}
