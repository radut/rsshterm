import Foundation

/// A secret used to log in. Lives only inside the decrypted `Vault`, never in plain storage.
public struct Credential: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case password(String)
        /// OpenSSH private key text; `passphrase` when the key itself is encrypted.
        case privateKey(pem: String, passphrase: String?)
    }

    public var id: UUID
    public var label: String
    public var kind: Kind

    public init(id: UUID = UUID(), label: String, kind: Kind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

/// Everything the user syncs: the plaintext document that `VaultCipher` seals.
public struct Vault: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var groups: [ServerGroup]
    public var servers: [Server]
    public var credentials: [Credential]
    /// Pinned SSH host keys (trust on first use). Absent in vaults written before it existed.
    public var knownHosts: [KnownHost]
    /// Settings › SSH agent forwarding defaults. Absent in vaults written before it existed (forwarding off).
    public var agentDefaults: AgentForwardingDefaults
    /// VNC, Apple Screen Sharing and RDP screens. Absent in vaults written before it existed.
    public var remoteDesktops: [RemoteDesktop]

    public init(groups: [ServerGroup] = [], servers: [Server] = [], credentials: [Credential] = [],
                knownHosts: [KnownHost] = [], agentDefaults: AgentForwardingDefaults = AgentForwardingDefaults(),
                remoteDesktops: [RemoteDesktop] = []) {
        self.version = Vault.currentVersion
        self.groups = groups
        self.servers = servers
        self.credentials = credentials
        self.knownHosts = knownHosts
        self.agentDefaults = agentDefaults
        self.remoteDesktops = remoteDesktops
    }

    private enum CodingKeys: String, CodingKey {
        case version, groups, servers, credentials, knownHosts, agentDefaults, remoteDesktops
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        groups = try c.decode([ServerGroup].self, forKey: .groups)
        servers = try c.decode([Server].self, forKey: .servers)
        credentials = try c.decode([Credential].self, forKey: .credentials)
        knownHosts = try c.decodeIfPresent([KnownHost].self, forKey: .knownHosts) ?? []
        agentDefaults = (try? c.decodeIfPresent(AgentForwardingDefaults.self, forKey: .agentDefaults)) ?? AgentForwardingDefaults()
        // One entry this build cannot read (a kind from a newer build) is left out, not the whole vault.
        remoteDesktops = (try? c.decodeIfPresent([Lossy<RemoteDesktop>].self, forKey: .remoteDesktops))?
            .compactMap(\.value) ?? []
    }

    /// Like the synthesized encoding, but a vault with no remote desktops writes no `remoteDesktops` key, so it
    /// stays byte-for-byte what older builds wrote.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(groups, forKey: .groups)
        try c.encode(servers, forKey: .servers)
        try c.encode(credentials, forKey: .credentials)
        try c.encode(knownHosts, forKey: .knownHosts)
        try c.encode(agentDefaults, forKey: .agentDefaults)
        if !remoteDesktops.isEmpty { try c.encode(remoteDesktops, forKey: .remoteDesktops) }
    }
}

/// An array element that decodes to nil instead of failing the array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}
