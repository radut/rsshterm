@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOSSH
import RSSHKit

/// One SSH login: where, as whom, with which secrets (tried in order), and the host keys pinned for it.
public struct SSHEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var username: String
    public var secrets: [Credential.Kind]
    public var knownHosts: [KnownHost]

    public init(host: String, port: Int = 22, username: String, secrets: [Credential.Kind], knownHosts: [KnownHost] = []) {
        self.host = host
        self.port = port
        self.username = username
        self.secrets = secrets
        self.knownHosts = knownHosts
    }

    /// `server` as saved in `vault`: its own credential first, then (with `agentKeys`) the other vault keys, as the
    /// built-in agent would offer them to `ssh`.
    public init(server: Server, in vault: Vault, agentKeys: Bool) {
        let own = server.credentialID.flatMap { id in vault.credentials.first { $0.id == id } }
        let logins = SSHLogins.plan(credential: own, vaultCredentials: vault.credentials, agentKeys: agentKeys)
        self.init(host: server.host, port: server.port, username: server.username, secrets: logins.map(\.kind),
                  knownHosts: vault.knownHosts)
    }

    public var displayName: String { ConnectionTarget(host: host, port: port, username: username).displayName }
}

/// The path to a server: zero or more jump hosts (ProxyJump order: first is dialled directly), then the target.
public struct SSHRoute: Sendable, Hashable {
    public var jumps: [SSHEndpoint]
    public var target: SSHEndpoint

    public init(jumps: [SSHEndpoint] = [], target: SSHEndpoint) {
        self.jumps = jumps
        self.target = target
    }

    /// `server` reached through `via` (already resolved from the server's jump chain, first hop first).
    public init(server: Server, in vault: Vault, via: [Server] = [], agentKeys: Bool) {
        self.init(jumps: via.map { SSHEndpoint(server: $0, in: vault, agentKeys: agentKeys) },
                  target: SSHEndpoint(server: server, in: vault, agentKeys: agentKeys))
    }

    /// `server` with its jump chain from the vault (`Vault.connectionHops`: saved servers with their own chains,
    /// inline hops). Each hop logs in with its own credential, then (with `agentKeys`) the other vault keys; an
    /// inline hop without a login of its own tries the vault keys that open without a prompt. Throws when the chain
    /// loops or is too deep.
    public static func resolve(_ server: Server, in vault: Vault, agentKeys: Bool) throws(JumpChainError) -> SSHRoute {
        let hops = try vault.connectionHops(to: server)
        let endpoints = hops.map { hop in
            let own = hop.credentialID.flatMap { id in vault.credentials.first { $0.id == id } }
            var logins = SSHLogins.plan(credential: own, vaultCredentials: vault.credentials, agentKeys: agentKeys)
            if logins.isEmpty, hop.serverID == nil {
                logins = QuickLogin.automatic(from: vault.credentials).compactMap { login in
                    login.credentialID.flatMap { id in vault.credentials.first { $0.id == id } }
                }
            }
            return SSHEndpoint(host: hop.target.host, port: hop.target.port, username: hop.target.username,
                               secrets: logins.map(\.kind), knownHosts: vault.knownHosts)
        }
        return SSHRoute(jumps: Array(endpoints.dropLast()), target: endpoints.last!)
    }

    /// Every hop, first jump host first, target last.
    public var hops: [SSHEndpoint] { jumps + [target] }
}

/// Why a route could not be opened, and at which hop (0 = the first jump host, or the target when there is none).
public enum RemoteConnectError: Error, Equatable, Sendable, LocalizedError {
    /// The hop's host key is not pinned: ask, pin `key` in the vault, connect again.
    case unknownHostKey(KnownHost, hop: Int)
    case changedHostKey(expected: KnownHost, presented: KnownHost, hop: Int)
    case failed(SSHFailure, hop: Int)

    public var hop: Int {
        switch self {
        case .unknownHostKey(_, let hop), .changedHostKey(_, _, let hop), .failed(_, let hop): hop
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unknownHostKey(let key, _): "\(key.host) presented a host key that is not trusted yet: \(key.fingerprint)"
        case let .changedHostKey(expected, presented, _):
            SSHFailure.hostKeyChanged(expected: expected.fingerprint, presented: presented.fingerprint).message
        case .failed(let failure, _): failure.message
        }
    }
}

/// An open route: the target's client and the jump clients it runs through. Close it when done.
public struct SSHConnection: Sendable {
    public struct Box: @unchecked Sendable { public let client: SSHClient }

    private let boxes: [Box]

    init(clients: [SSHClient]) { boxes = clients.map(Box.init) }

    /// The client logged in on the route's target.
    public var target: SSHClient { boxes[boxes.count - 1].client }
    /// Target first, then the jump hosts from the last to the first: the order to close them in.
    public var clientsTargetFirst: [SSHClient] { boxes.reversed().map(\.client) }

    public func close() async {
        for client in clientsTargetFirst { try? await client.close() }
    }
}

/// Opens SSH routes with Citadel: each hop's host key checked against the pinned keys, its secrets tried in order,
/// jump hosts through direct-tcpip channels of the hop before (like `ssh -J`).
public struct SSHConnector: Sendable {
    public var connectTimeout: TimeAmount

    public init(connectTimeout: TimeAmount = .seconds(15)) { self.connectTimeout = connectTimeout }

    /// NIOSSH alone offers only AES-GCM; a hardened OpenSSH that allows just aes*-ctr + hmac-sha2-* needs Citadel's
    /// AES-128-CTR as the fallback (GCM stays first).
    public static var algorithms: SSHAlgorithms {
        var algorithms = SSHAlgorithms()
        algorithms.transportProtectionSchemes = .add([AES128CTR.self])
        return algorithms
    }

    public func connect(_ route: SSHRoute) async throws(RemoteConnectError) -> SSHConnection {
        var clients: [SSHClient] = []
        for (index, hop) in route.hops.enumerated() {
            let auth: SSHAuthenticationMethod
            do { auth = try SSHLogins.method(username: hop.username, secrets: hop.secrets) } catch {
                await SSHConnection(clients: clients).closeIfAny()
                throw .failed(error, hop: index)
            }
            let gate = PinnedHostKeyValidator(host: hop.host, port: hop.port, known: hop.knownHosts)
            do {
                if let previous = clients.last {
                    let secrets = hop.secrets
                    let username = hop.username
                    var settings = SSHClientSettings(host: hop.host, port: hop.port, authenticationMethod: {
                        // A fresh chain per handshake (a chain is used up as it goes); it was built once above,
                        // so it does not throw here, and an empty chain would only fail the login.
                        (try? SSHLogins.method(username: username, secrets: secrets)) ?? .custom(SSHLoginChain([]))
                    }, hostKeyValidator: .custom(gate))
                    settings.algorithms = Self.algorithms
                    settings.connectTimeout = connectTimeout
                    clients.append(try await previous.jump(to: settings))
                } else {
                    clients.append(try await SSHClient.connect(
                        host: hop.host, port: hop.port, authenticationMethod: auth, hostKeyValidator: .custom(gate),
                        reconnect: .never, algorithms: Self.algorithms, connectTimeout: connectTimeout))
                }
            } catch {
                await SSHConnection(clients: clients).closeIfAny()
                switch gate.refusal {
                case .unknown(let key)?: throw .unknownHostKey(key, hop: index)
                case .changed(let expected, let presented)?:
                    throw .changedHostKey(expected: expected, presented: presented, hop: index)
                case nil: throw .failed(RemoteErrorMapper.failure(for: error, host: hop.host), hop: index)
                }
            }
        }
        return SSHConnection(clients: clients)
    }

    /// Connects the route and opens SFTP on its target; the source owns the connection.
    public func openSFTP(_ route: SSHRoute, id: String, displayName: String) async throws -> SFTPFileSource {
        let connection = try await connect(route)
        return try await SFTPFileSource.open(over: connection, id: id, displayName: displayName)
    }
}

extension SSHConnection {
    fileprivate func closeIfAny() async {
        guard !boxes.isEmpty else { return }
        await close()
    }
}
