import Foundation

/// One entry of an OpenSSH ProxyJump list: `[user@]host[:port]`, `[v6]:port` or `ssh://[user@]host[:port]`.
public struct ProxyJumpEntry: Hashable, Sendable {
    public var username: String?
    public var host: String
    public var port: Int?

    public init(username: String?, host: String, port: Int?) {
        self.username = username
        self.host = host
        self.port = port
    }
}

public enum ProxyJumpError: Error, Hashable, Sendable, LocalizedError {
    case emptyEntry
    case invalidEntry(String)
    case tooMany(max: Int)

    public var message: String {
        switch self {
        case .emptyEntry: "A jump host is empty: remove the extra comma."
        case .invalidEntry(let text): "“\(text)” is not a jump host. Use host, user@host or user@host:port."
        case .tooMany(let max): "At most \(max) jump hosts."
        }
    }

    public var errorDescription: String? { message }
}

/// Reads and writes OpenSSH ProxyJump syntax ("bastion,ops@gw:2222"), for Quick Connect's "via" field and imports.
public enum ProxyJump {
    /// The entries in order; "" and "none" mean no jump. Refuses anything ssh_config could read another way.
    public static func parse(_ text: String) throws(ProxyJumpError) -> [ProxyJumpEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return [] }
        var entries: [ProxyJumpEntry] = []
        for piece in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let item = piece.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { throw .emptyEntry }
            guard let entry = entry(item) else { throw .invalidEntry(item) }
            entries.append(entry)
        }
        guard entries.count <= JumpChain.maxHops else { throw .tooMany(max: JumpChain.maxHops) }
        return entries
    }

    /// The ProxyJump text for `entries`; IPv6 hosts in brackets when a port follows.
    public static func format(_ entries: [ProxyJumpEntry]) -> String {
        entries.map { entry in
            let user = entry.username.map { "\($0)@" } ?? ""
            guard let port = entry.port else { return user + entry.host }
            let host = entry.host.contains(":") ? "[\(entry.host)]" : entry.host
            return "\(user)\(host):\(port)"
        }.joined(separator: ",")
    }

    /// The jump list for `text`: an entry naming a saved server (by name, or by host with a matching user and port)
    /// becomes a reference to it; any other an inline hop with `defaultUsername`, port 22 and `credentialID`.
    public static func jumpHosts(from text: String, servers: [Server], defaultUsername: String,
                                 credentialID: UUID?) throws(ProxyJumpError) -> [JumpHost] {
        try parse(text).map { entry in
            if let server = match(entry, in: servers) { return .server(server.id) }
            return .inline(InlineJumpHost(host: entry.host, port: entry.port ?? 22,
                                          username: entry.username ?? defaultUsername, credentialID: credentialID))
        }
    }

    /// The ProxyJump text of a jump list: saved servers by name when the name reads back as one, else user@host:port.
    /// Deleted servers are left out.
    public static func text(for jumps: [JumpHost], servers: [Server]) -> String {
        let entries = jumps.compactMap { jump -> ProxyJumpEntry? in
            switch jump {
            case .server(let id):
                guard let server = servers.first(where: { $0.id == id }) else { return nil }
                if let named = try? parse(server.name), named == [ProxyJumpEntry(username: nil, host: server.name, port: nil)] {
                    return named[0]
                }
                return ProxyJumpEntry(username: server.username, host: server.host, port: server.port == 22 ? nil : server.port)
            case .inline(let hop):
                return ProxyJumpEntry(username: hop.username, host: hop.host, port: hop.port == 22 ? nil : hop.port)
            }
        }
        return format(entries)
    }

    // MARK: parsing

    private static func match(_ entry: ProxyJumpEntry, in servers: [Server]) -> Server? {
        let host = entry.host.lowercased()
        if entry.username == nil, entry.port == nil, let named = servers.first(where: { $0.name.lowercased() == host }) {
            return named
        }
        return servers.first { server in
            server.host.lowercased() == host && (entry.username ?? server.username) == server.username
                && (entry.port ?? server.port) == server.port
        }
    }

    private static func entry(_ text: String) -> ProxyJumpEntry? {
        var rest = Substring(text)
        if rest.lowercased().hasPrefix("ssh://") { rest = rest.dropFirst(6) }
        let parts = rest.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        var username: String?
        if parts.count == 2 {
            guard isSafeUsername(parts[0]) else { return nil }
            username = String(parts[0])
        }
        guard let address = parts.last, let (host, port) = QuickAddress.hostAndPort(address), isSafeHost(host) else {
            return nil
        }
        return ProxyJumpEntry(username: username, host: host, port: port)
    }

    /// Letters, digits, dot, dash, underscore and the colons of IPv6; never a leading dash (an ssh option).
    static func isSafeHost(_ host: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:"))
        return !host.isEmpty && !host.hasPrefix("-") && host.count <= 253
            && host.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    static func isSafeUsername<S: StringProtocol>(_ name: S) -> Bool {
        let unsafe = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"'#*?!,%\\@[]:/"))
        return !name.isEmpty && !name.hasPrefix("-") && !name.unicodeScalars.contains(where: unsafe.contains)
    }
}
