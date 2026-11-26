import Foundation

/// Where "Add to Folder" puts the servers a scan found.
public enum ScanDestination: Hashable, Sendable {
    /// The top-level Servers list.
    case ungrouped
    case folder(UUID)
    /// A new folder of this name; an existing folder of the same name (any case) is used instead.
    case newFolder(String)
}

/// How the servers a scan found log in.
public enum DiscoveredLogin: Hashable, Sendable {
    /// No saved login: a password is asked for when connecting.
    case none
    /// A password or key already in the vault.
    case saved(UUID)
    /// A password or key to save now, once, shared by every server of the batch.
    case new(Credential)

    /// A password typed for the batch, saved as one new vault password.
    public static func newPassword(_ secret: String, label: String) -> DiscoveredLogin {
        .new(Credential(label: label, kind: .password(secret)))
    }

    /// The label of a password typed for a scan: "user@range", or "<user or range> password".
    public static func label(username: String, range: String) -> String {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = range.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (user.isEmpty, range.isEmpty) {
        case (false, false): return "\(user)@\(range)"
        case (false, true): return "\(user) password"
        case (true, false): return "\(range) password"
        case (true, true): return "Scan password"
        }
    }
}

public struct DiscoveredImport: Sendable {
    public var vault: Vault
    public var added: [Server]
    /// The password or key saved for this batch (`DiscoveredLogin.new`), nil when none was saved.
    public var credential: Credential?
    /// The screens (RDP, VNC) added as services of new or saved servers.
    public var screens: [RemoteDesktop] = []
    /// Hosts left out because a server with the same host and port is already saved (or was listed twice).
    public var skipped: [DiscoveredHost]
}

extension Vault {
    /// True when a saved server has this host (any case) and port.
    public func hasServer(host: String, port: Int) -> Bool {
        servers.contains { $0.port == port && $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    /// One server per host not saved yet, named by `DiscoveredHost.suggestedName`, logging in as `username` with
    /// `login` and going through `jumpHosts` (the server editor's Jump Through list, checked the same way). A host
    /// found on 3389 or 5900 gets that screen (RDP, VNC) as a service of its server: of the SSH server this batch adds
    /// for the same host, else of a saved server with that host when `screensJoinSavedServers` (the user said so),
    /// else of a new server with SSH off. A new folder or a new password is only saved when something is added; the
    /// login and the jump servers are checked even when nothing is.
    public func addingDiscovered(_ hosts: [DiscoveredHost], to destination: ScanDestination, username: String,
                                 login: DiscoveredLogin = .none, jumpHosts: [JumpHost] = [],
                                 screensJoinSavedServers: Bool = false) throws(VaultEditError) -> DiscoveredImport {
        try check(login)
        for case .server(let id) in jumpHosts where !servers.contains(where: { $0.id == id }) {
            throw .jumpChain(.missingServer(id))
        }
        let (fresh, screens, skipped) = sorted(hosts, joining: screensJoinSavedServers)
        guard !fresh.isEmpty || !screens.isEmpty else {
            return DiscoveredImport(vault: self, added: [], credential: nil, skipped: skipped)
        }
        var vault = self
        let groupID = try vault.resolve(destination)
        var saved: Credential?
        var credentialID: UUID?
        switch login {
        case .none: break
        case .saved(let id): credentialID = id
        case .new(let credential):
            vault = try vault.addingCredential(credential)
            saved = vault.credentials.last
            credentialID = credential.id
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var added: [Server] = []
        func newServer(_ host: DiscoveredHost, ssh: Bool) throws(VaultEditError) -> Server {
            var server = Server(name: host.suggestedName, host: host.host, port: host.port, username: user,
                                credentialID: credentialID, groupID: groupID)
            server.jumpHosts = jumpHosts
            server.sshEnabled = ssh
            vault = try vault.addingServer(server)
            added.append(server)
            return server
        }
        for host in fresh { _ = try newServer(host, ssh: true) }
        var addedScreens: [RemoteDesktop] = []
        for host in screens {
            guard let service = ScreenService(port: host.port) else { continue }
            var owner = added.first { Self.same($0.host, host.host) }
                ?? (screensJoinSavedServers ? vault.servers(matchingHost: host.host).first : nil)
            if owner == nil {
                owner = try newServer(DiscoveredHost(host: host.host, dnsName: host.dnsName, serviceName: host.serviceName),
                                      ssh: false)
            }
            guard let owner else { continue }
            var screen = vault.newService(service, for: owner)
            screen.port = host.port
            vault = try vault.addingRemoteDesktop(screen)
            addedScreens.append(screen)
        }
        return DiscoveredImport(vault: vault, added: added, credential: saved, screens: addedScreens, skipped: skipped)
    }

    /// Saved servers a found screen (3389, 5900) would join if the user agrees: the question before "Add".
    public func serversForDiscoveredScreens(_ hosts: [DiscoveredHost]) -> [Server] {
        var found: [Server] = []
        for host in hosts {
            guard let service = ScreenService(port: host.port) else { continue }
            for server in servers(matchingHost: host.host)
            where self.service(service, of: server.id) == nil && !found.contains(server) {
                found.append(server)
            }
        }
        return found
    }

    /// Splits the found hosts into SSH servers to add, screens to add and hosts left out (saved already, or listed
    /// twice).
    private func sorted(_ hosts: [DiscoveredHost], joining: Bool)
        -> (ssh: [DiscoveredHost], screens: [DiscoveredHost], skipped: [DiscoveredHost]) {
        var ssh: [DiscoveredHost] = [], screens: [DiscoveredHost] = [], skipped: [DiscoveredHost] = []
        for host in hosts {
            if let service = ScreenService(port: host.port) {
                let listed = screens.contains { Self.same($0.host, host.host) && ScreenService(port: $0.port) == service }
                if listed || hasScreen(service, host: host.host, joining: joining) { skipped.append(host) } else { screens.append(host) }
            } else {
                let listed = ssh.contains { $0.port == host.port && Self.same($0.host, host.host) }
                if listed || hasServer(host: host.host, port: host.port) { skipped.append(host) } else { ssh.append(host) }
            }
        }
        return (ssh, screens, skipped)
    }

    /// A screen of this service already reaches `host`: saved on its own straight to it, or as a service of a server
    /// with that host (only counted when the screen would join that server).
    private func hasScreen(_ service: ScreenService, host: String, joining: Bool) -> Bool {
        let standalone = standaloneRemoteDesktops.contains {
            ScreenService($0.kind) == service && $0.transport == .direct && Self.same($0.host, host)
        }
        let joined = joining && servers(matchingHost: host).contains { self.service(service, of: $0.id) != nil }
        return standalone || joined
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    /// A saved login must exist; a new one must be a valid password or key (checked by adding it to a scratch copy).
    private func check(_ login: DiscoveredLogin) throws(VaultEditError) {
        switch login {
        case .none: return
        case .saved(let id): guard credentials.contains(where: { $0.id == id }) else { throw .unknownCredential }
        case .new(let credential): _ = try addingCredential(credential)
        }
    }

    private mutating func resolve(_ destination: ScanDestination) throws(VaultEditError) -> UUID? {
        switch destination {
        case .ungrouped:
            return nil
        case .folder(let id):
            guard groups.contains(where: { $0.id == id }) else { throw .unknownGroup }
            return id
        case .newFolder(let raw):
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return existing.id
            }
            let group = ServerGroup(name: name)
            self = try addingGroup(group)
            return group.id
        }
    }
}
