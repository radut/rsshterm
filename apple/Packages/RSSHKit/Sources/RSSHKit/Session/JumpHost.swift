import Foundation

/// A host typed into a jump chain rather than saved as a server: user@host:port and which vault login to use.
public struct InlineJumpHost: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    /// The vault password or key for this hop; nil uses the key of the server whose list holds this hop (never a
    /// password: that would hand one server's password to another host).
    public var credentialID: UUID?

    public init(host: String, port: Int = 22, username: String, credentialID: UUID? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.credentialID = credentialID
    }

    public var target: ConnectionTarget { ConnectionTarget(host: host, port: port, username: username) }

    /// "user@host", with ":port" when it is not 22 (an IPv6 address then in brackets).
    public var displayName: String {
        guard port != 22 else { return "\(username)@\(host)" }
        let shown = host.contains(":") ? "[\(host)]" : host
        return "\(username)@\(shown):\(port)"
    }
}

/// One hop a connection goes through before its server (OpenSSH's ProxyJump / `ssh -J`).
public enum JumpHost: Hashable, Sendable {
    /// Another server of the vault, with its own user, port, login, pinned host key and its own jump chain.
    case server(UUID)
    case inline(InlineJumpHost)
}

extension JumpHost: Codable {
    private enum CodingKeys: String, CodingKey { case serverID, host, port, username, credentialID }

    /// Flat objects: `{"serverID": …}` or `{"host", "port", "username", "credentialID"?}`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .serverID) {
            self = .server(id)
            return
        }
        self = .inline(InlineJumpHost(host: try c.decode(String.self, forKey: .host),
                                      port: try c.decodeIfPresent(Int.self, forKey: .port) ?? 22,
                                      username: try c.decode(String.self, forKey: .username),
                                      credentialID: try c.decodeIfPresent(UUID.self, forKey: .credentialID)))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .server(let id):
            try c.encode(id, forKey: .serverID)
        case .inline(let hop):
            try c.encode(hop.host, forKey: .host)
            try c.encode(hop.port, forKey: .port)
            try c.encode(hop.username, forKey: .username)
            try c.encodeIfPresent(hop.credentialID, forKey: .credentialID)
        }
    }
}

/// One step of a resolved connection: where to connect and with which login.
public struct ConnectionHop: Hashable, Sendable {
    /// The server's name, or user@host[:port] for an inline hop: what messages and prompts call this hop.
    public var name: String
    public var target: ConnectionTarget
    public var credentialID: UUID?
    /// The vault server this hop is, nil for an inline hop.
    public var serverID: UUID?

    public init(name: String, target: ConnectionTarget, credentialID: UUID?, serverID: UUID?) {
        self.name = name
        self.target = target
        self.credentialID = credentialID
        self.serverID = serverID
    }
}

/// Why a jump chain cannot be followed. Messages are shown to the user as they are.
public enum JumpChainError: Error, Hashable, Sendable, LocalizedError {
    /// The servers (by name) that lead back to the first one, first name repeated at the end.
    case cycle([String])
    case tooDeep(max: Int)
    case missingServer(UUID)

    public var message: String {
        switch self {
        case .cycle(let names):
            "The jump hosts go round in a circle: \(names.joined(separator: " › ")). Remove one of them."
        case .tooDeep(let max):
            "Too many jump hosts: at most \(max) hops, counting those of the jump servers themselves."
        case .missingServer:
            "A jump host of this server no longer exists. Pick another one in the server's Jump Through list."
        }
    }

    public var errorDescription: String? { message }
}

/// Turns a server into the ordered hops a connection goes through, its jump chain expanded.
public enum JumpChain {
    /// The most hops before the server itself, as OpenSSH's own limit is far away and every hop costs a handshake.
    public static let maxHops = 5

    /// The hops in connection order; the last one is `server`. A referenced server brings its own chain first.
    /// An inline hop without a login takes the login of the server whose list holds it, but only when that login's
    /// id is in `inheritable` (the vault's keys: a password is never sent to another host).
    public static func hops(to server: Server, in servers: [Server],
                            inheritable: Set<UUID> = []) throws(JumpChainError) -> [ConnectionHop] {
        let byID = Dictionary(servers.map { ($0.id, $0) }) { first, _ in first }
        var hops: [ConnectionHop] = []
        try append(server, inheritable: inheritable, byID: byID, stack: [], into: &hops)
        return hops
    }

    /// Checks that the chain can be followed, without needing the hops.
    public static func validate(_ server: Server, in servers: [Server]) throws(JumpChainError) {
        _ = try hops(to: server, in: servers)
    }

    /// "via bastion, ops@gw" for the server list; nil without jumps. Lists the direct jumps only.
    public static func summary(of server: Server, in servers: [Server]) -> String? {
        guard !server.jumpHosts.isEmpty else { return nil }
        let names = server.jumpHosts.map { jump -> String in
            switch jump {
            case .server(let id): servers.first { $0.id == id }?.name ?? "(deleted server)"
            case .inline(let hop): hop.displayName
            }
        }
        return "via " + names.joined(separator: ", ")
    }

    private static func append(_ server: Server, inheritable: Set<UUID>, byID: [UUID: Server], stack: [Server],
                               into hops: inout [ConnectionHop]) throws(JumpChainError) {
        if let start = stack.firstIndex(where: { $0.id == server.id }) {
            throw .cycle(stack[start...].map(\.name) + [server.name])
        }
        let path = stack + [server]
        for jump in server.jumpHosts {
            switch jump {
            case .server(let id):
                guard let next = byID[id] else { throw .missingServer(id) }
                try append(next, inheritable: inheritable, byID: byID, stack: path, into: &hops)
            case .inline(let hop):
                let inherited = server.credentialID.flatMap { inheritable.contains($0) ? $0 : nil }
                try push(ConnectionHop(name: hop.displayName, target: hop.target,
                                       credentialID: hop.credentialID ?? inherited, serverID: nil), into: &hops)
            }
        }
        try push(ConnectionHop(name: server.name, target: ConnectionTarget(server: server),
                               credentialID: server.credentialID, serverID: server.id), into: &hops)
    }

    /// The server itself always comes last, so more than `maxHops + 1` at any point is too many jumps.
    private static func push(_ hop: ConnectionHop, into hops: inout [ConnectionHop]) throws(JumpChainError) {
        hops.append(hop)
        if hops.count > maxHops + 1 { throw .tooDeep(max: maxHops) }
    }
}

extension Vault {
    /// The hops to reach `server`, its jump chain expanded (`JumpChain.hops`); inline hops without a login inherit
    /// their server's key, never its password.
    public func connectionHops(to server: Server) throws(JumpChainError) -> [ConnectionHop] {
        let keys = credentials.filter { if case .privateKey = $0.kind { true } else { false } }.map(\.id)
        return try JumpChain.hops(to: server, in: servers, inheritable: Set(keys))
    }
}
