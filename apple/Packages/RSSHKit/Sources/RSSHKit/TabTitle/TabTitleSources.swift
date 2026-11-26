import Foundation

/// The foreground of a local tab, read from its PTY (desktop): the job's argv (nil while the shell waits at its
/// prompt), the shell's folder and this machine's user and host.
public struct LocalProcessFacts: Equatable, Sendable {
    public var foreground: [String]?
    public var cwd: String?
    public var user: String?
    public var host: String?
    public var home: String?

    public init(foreground: [String]?, cwd: String?, user: String?, host: String?, home: String? = nil) {
        self.foreground = foreground
        self.cwd = cwd
        self.user = user
        self.host = host
        self.home = home
    }
}

/// What rsshd reports for a session's pane (`Session.pane` / the `pane` event): an empty command means the shell
/// waits at its prompt.
public struct PaneReport: Equatable, Sendable, Codable {
    public var command: String
    public var args: [String]
    public var cwd: String

    public init(command: String, args: [String], cwd: String) {
        self.command = command
        self.args = args
        self.cwd = cwd
    }
}

/// Where an `ssh` typed in a local tab resolves its aliases: the user's ssh_config and the vault by alias.
public struct SSHResolveContext: Sendable {
    public var config: SSHConfigHosts
    public var vault: [String: VaultHostFacts]

    public init(config: SSHConfigHosts, vault: [String: VaultHostFacts]) {
        self.config = config
        self.vault = vault
    }
}

/// Every source of facts for one tab, merged by `facts()` with the best source first for each field:
///
/// 1. rsshd's pane report (process, args, cwd of the session's foreground job);
/// 2. the shell (OSC 2 prompt/command titles, OSC 7 folder; the rSSH shell integration sends both);
/// 3. the local PTY's foreground process (desktop local tabs; `ssh host` there gives user/host);
/// 4. the vault server of an SSH tab (known before anything else).
public struct TabTitleSources: Sendable {
    public var custom: String?
    public var index: Int?
    public var vault: VaultHostFacts?
    public var local: LocalProcessFacts?
    public var sshContext: SSHResolveContext?
    /// The last OSC 0/2 title.
    public var terminalTitle: String?
    /// The last OSC 7 report.
    public var directory: DirectoryReport?
    public var daemon: PaneReport?

    public init(custom: String? = nil, index: Int? = nil, vault: VaultHostFacts? = nil,
                local: LocalProcessFacts? = nil, sshContext: SSHResolveContext? = nil, terminalTitle: String? = nil,
                directory: DirectoryReport? = nil, daemon: PaneReport? = nil) {
        self.custom = custom
        self.index = index
        self.vault = vault
        self.local = local
        self.sshContext = sshContext
        self.terminalTitle = terminalTitle
        self.directory = directory
        self.daemon = daemon
    }

    public func facts() -> TabTitleFacts {
        var f = TabTitleFacts(custom: TabTitleFacts.nonEmpty(custom), index: index)
        f.title = TabTitleFacts.nonEmpty(terminalTitle)
        // 4. vault
        if let vault {
            f.server = TabTitleFacts.nonEmpty(vault.name)
            f.user = vault.user
            f.host = vault.host
        }
        // 3. local process
        var remote = vault != nil
        if let local {
            if let argv = local.foreground, let ssh = SSHCommandLine.parse(argv) {
                let context = sshContext ?? SSHResolveContext(config: SSHConfigHosts(text: ""), vault: [:])
                let target = ssh.resolved(config: context.config, vault: context.vault)
                f.user = target.user ?? f.user
                f.host = target.host
                f.alias = target.alias
                f.server = target.server ?? f.server
                remote = true
            } else if !remote {
                f.user = local.user
                f.host = local.host
                f.cwd = local.cwd
                f.home = local.home
                if let argv = local.foreground {
                    let command = CommandFacts(argv: argv)
                    f.process = command.process
                    f.args = command.args
                }
            }
        }
        // 2. the shell's own reports
        if remote, let title = terminalTitle, let parsed = TerminalTitleParser.parse(title) {
            switch parsed {
            case .prompt(let user, let host, let cwd):
                f.user = user
                f.host = host
                f.cwd = cwd
                f.process = nil
                f.args = []
            case .running(let user, let host, let commandLine):
                f.user = user
                f.host = host
                let command = CommandFacts(commandLine: commandLine)
                f.process = command.process
                f.args = command.args
            }
        }
        if let directory, remote || local == nil {
            f.cwd = directory.path
        }
        // 1. rsshd
        if let daemon {
            let command = daemon.command.trimmingCharacters(in: .whitespaces)
            f.process = command.isEmpty ? nil : CommandFacts.programName(command)
            f.args = command.isEmpty ? [] : daemon.args
            if !daemon.cwd.isEmpty { f.cwd = daemon.cwd }
        }
        if remote, f.home == nil {
            f.home = TitleText.guessHome(user: f.user, path: f.cwd)
        }
        return f
    }
}
