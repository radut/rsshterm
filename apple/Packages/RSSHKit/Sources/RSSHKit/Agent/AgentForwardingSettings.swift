import Foundation

/// A per-server switch that can also follow the global default.
public enum AgentSwitch: String, Codable, CaseIterable, Sendable {
    case `default`, on, off

    func resolved(_ fallback: Bool) -> Bool {
        switch self {
        case .default: fallback
        case .on: true
        case .off: false
        }
    }
}

/// Which vault keys a server may use through the forwarded agent.
public enum AgentKeyScope: Codable, Hashable, Sendable {
    /// Only the key this server logs in with (the default).
    case serverKey
    case allKeys
    /// These credentials, in vault order; ids no longer in the vault are skipped.
    case selected([UUID])
}

/// Settings › SSH: the global defaults, kept in the vault so they sync.
public struct AgentForwardingDefaults: Codable, Hashable, Sendable {
    public var forwardAgent: Bool
    public var askBeforeUse: Bool
    /// Allow in the confirm prompt needs Face ID (or the passcode) first.
    public var confirmWithFaceID: Bool

    public init(forwardAgent: Bool = false, askBeforeUse: Bool = true, confirmWithFaceID: Bool = false) {
        self.forwardAgent = forwardAgent
        self.askBeforeUse = askBeforeUse
        self.confirmWithFaceID = confirmWithFaceID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentForwardingDefaults()
        forwardAgent = (try? c.decodeIfPresent(Bool.self, forKey: .forwardAgent)) ?? d.forwardAgent
        askBeforeUse = (try? c.decodeIfPresent(Bool.self, forKey: .askBeforeUse)) ?? d.askBeforeUse
        confirmWithFaceID = (try? c.decodeIfPresent(Bool.self, forKey: .confirmWithFaceID)) ?? d.confirmWithFaceID
    }
}

/// The server editor's agent rows. A server without them (older vaults) follows the defaults with its own key.
public struct ServerAgentSettings: Codable, Hashable, Sendable {
    public var forward: AgentSwitch
    public var keys: AgentKeyScope
    public var askBeforeUse: AgentSwitch

    public init(forward: AgentSwitch = .default, keys: AgentKeyScope = .serverKey, askBeforeUse: AgentSwitch = .default) {
        self.forward = forward
        self.keys = keys
        self.askBeforeUse = askBeforeUse
    }

    /// Unknown values (from a newer build) fall back to the defaults instead of failing the whole vault.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServerAgentSettings()
        forward = (try? c.decodeIfPresent(AgentSwitch.self, forKey: .forward)) ?? d.forward
        keys = (try? c.decodeIfPresent(AgentKeyScope.self, forKey: .keys)) ?? d.keys
        askBeforeUse = (try? c.decodeIfPresent(AgentSwitch.self, forKey: .askBeforeUse)) ?? d.askBeforeUse
    }
}

/// What one session forwards: nil from `plan` means no forwarding.
public struct AgentForwardingPlan: Equatable, Sendable {
    /// Credential ids of the keys offered, in vault order (may be empty: the agent then lists nothing).
    public let keyIDs: [UUID]
    public let askBeforeUse: Bool

    /// Resolves server over global. `server` is nil for Quick Connect, which forwards only when the global default
    /// is on and then offers only the key it logs in with.
    public static func plan(server: Server?, loginCredentialID: UUID?, defaults: AgentForwardingDefaults,
                            credentials: [Credential]) -> AgentForwardingPlan? {
        let settings = server?.agentForwarding ?? ServerAgentSettings()
        guard settings.forward.resolved(defaults.forwardAgent) else { return nil }
        let keys = credentials.filter { if case .privateKey = $0.kind { true } else { false } }
        let ids: [UUID] = switch settings.keys {
        case .serverKey: keys.filter { $0.id == loginCredentialID }.map(\.id)
        case .allKeys: keys.map(\.id)
        case .selected(let chosen): keys.filter { chosen.contains($0.id) }.map(\.id)
        }
        return AgentForwardingPlan(keyIDs: ids, askBeforeUse: settings.askBeforeUse.resolved(defaults.askBeforeUse))
    }
}
