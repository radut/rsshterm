import Foundation
import RSSHDesktopCore
import RSSHKit

/// What a terminal pane runs: the executable, argv (argv[0] included, "-bash" for a login shell), the environment
/// and the directory. VTE spawns it on its own PTY.
public struct SpawnPlan: Equatable, Sendable {
    public let executable: String
    public let argv: [String]
    public let environment: [String: String]
    public let directory: String?
    /// The tab title until the terminal sets its own.
    public let title: String

    /// `KEY=value` strings for `vte_terminal_spawn_async`, sorted so runs are reproducible.
    public var environmentList: [String] { environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } }
}

public enum SpawnError: Error, Equatable, Sendable, LocalizedError {
    case unknownServer
    /// The server's host or user cannot go in ssh_config, so it has no alias.
    case notInSSHConfig(String)
    case command(String)

    public var errorDescription: String? {
        switch self {
        case .unknownServer: "This server is no longer in the vault."
        case .notInSSHConfig(let name): "\(name) has a host or user name ssh_config cannot hold; edit it in the vault."
        case .command(let m): m
        }
    }
}

/// Builds `SpawnPlan`s: local tabs get the core's shell environment (SSH_AUTH_SOCK = the built-in agent,
/// TERM_PROGRAM=rSshTerm); an SSH pane is OpenSSH on the generated ssh_config: `ssh <alias>` when ~/.ssh/config
/// includes it, else `ssh -F <generated> <alias>`.
public struct SpawnPlanner: Sendable {
    public let environment: [String: String]
    public let agentSocket: String?
    public let appVersion: String
    public let sshConfigPath: String
    public let includeInstalled: Bool

    public init(environment: [String: String], agentSocket: String?, appVersion: String, sshConfigPath: String,
                includeInstalled: Bool) {
        self.environment = environment
        self.agentSocket = agentSocket
        self.appVersion = appVersion
        self.sshConfigPath = sshConfigPath
        self.includeInstalled = includeInstalled
    }

    /// `override`: "Try another login…" on an ssh pane, its user and login before the alias.
    public func plan(_ content: PaneContent, servers: [Server],
                     override: SSHLoginOverride? = nil) -> Result<SpawnPlan, SpawnError> {
        let tabEnv = ShellEnvironment.make(base: environment, agentSocket: agentSocket, appVersion: appVersion)
        switch content {
        case .localShell(nil, let directory):
            do {
                let config = try PTYConfiguration.shell(environment: environment, agentSocket: agentSocket,
                                                        appVersion: appVersion, directory: directory)
                let name = (config.executable as NSString).lastPathComponent
                return .success(SpawnPlan(executable: config.executable, argv: config.arguments,
                                          environment: config.environment, directory: config.directory, title: name))
            } catch {
                return .failure(.command("\(error)"))
            }
        case .localShell(let command?, let directory):
            guard let first = command.first, let path = ShellEnvironment.resolve(first, path: tabEnv["PATH"]) else {
                return .failure(.command("Command not found: \(command.first ?? "")"))
            }
            return .success(SpawnPlan(executable: path, argv: command, environment: tabEnv,
                                      directory: directory ?? environment["HOME"], title: first))
        case .remoteDesktop:
            return .failure(.command("A remote desktop is not a terminal."))
        case .ssh(let serverID):
            guard let server = servers.first(where: { $0.id == serverID }) else { return .failure(.unknownServer) }
            guard let alias = SSHConfigGenerator.aliases(for: servers)[serverID] else {
                return .failure(.notInSSHConfig(server.name))
            }
            let argv = (includeInstalled ? ["ssh"] : ["ssh", "-F", sshConfigPath]) + (override?.arguments ?? []) + [alias]
            guard let ssh = ShellEnvironment.resolve("ssh", path: tabEnv["PATH"]) else {
                return .failure(.command("OpenSSH (ssh) is not installed."))
            }
            return .success(SpawnPlan(executable: ssh, argv: argv, environment: tabEnv,
                                      directory: environment["HOME"], title: server.name))
        }
    }
}
