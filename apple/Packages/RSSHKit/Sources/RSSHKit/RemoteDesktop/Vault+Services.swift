import Foundation

/// A screen a server can be opened as, next to (or instead of) SSH.
public enum ScreenService: String, CaseIterable, Hashable, Sendable {
    case rdp
    /// VNC or Apple Screen Sharing (the screen's editor picks which).
    case vnc

    public init(_ kind: RemoteDesktop.Kind) { self = kind == .rdp ? .rdp : .vnc }

    /// The kind a new screen of this service starts as.
    public var defaultKind: RemoteDesktop.Kind { self == .rdp ? .rdp : .vnc }

    public var title: String { self == .rdp ? "Remote Desktop (RDP)" : "VNC / Screen Sharing" }

    /// The short name on toggles and menus ("RDP", "VNC").
    public var shortTitle: String { self == .rdp ? "RDP" : "VNC" }

    /// The service a scanned port stands for: 3389 is RDP, 5900-5909 VNC; anything else is SSH (nil).
    public init?(port: Int) {
        switch port {
        case 3389: self = .rdp
        case 5900...5909: self = .vnc
        default: return nil
        }
    }
}

/// A screen saved on its own whose host is a saved server's: "Add it to that server?" (never done unasked).
public struct MergeSuggestion: Hashable, Sendable {
    public var desktop: RemoteDesktop
    public var server: Server
}

/// What opening a server does: its SSH terminal, or (SSH off) its first screen.
public enum ServerOpening: Hashable, Sendable {
    case ssh
    case screen(UUID)
}

extension Vault {
    /// SSH when it is on (or the server has no screen); else its first screen, RDP before VNC.
    public func opening(_ server: Server) -> ServerOpening {
        guard !server.sshEnabled, let first = services(of: server.id).first else { return .ssh }
        return .screen(first.id)
    }

    /// The screens that are services of this server, RDP first.
    public func services(of serverID: UUID) -> [RemoteDesktop] {
        remoteDesktops.filter { $0.serverID == serverID }.sorted { ScreenService($0.kind) == .rdp && ScreenService($1.kind) != .rdp }
    }

    public func service(_ service: ScreenService, of serverID: UUID) -> RemoteDesktop? {
        remoteDesktops.first { $0.serverID == serverID && ScreenService($0.kind) == service }
    }

    /// Screens saved on their own (not a server's service), as the remote desktop list shows them.
    public var standaloneRemoteDesktops: [RemoteDesktop] { remoteDesktops.filter { $0.serverID == nil } }

    /// A new screen of `service` for `server`: through the server's own SSH connection to "localhost" when SSH is
    /// on, else straight to its host; the SSH account, and its login when that is a password ("Copy from SSH").
    public func newService(_ service: ScreenService, for server: Server) -> RemoteDesktop {
        let kind = service.defaultKind
        let password = server.credentialID.flatMap { id in credentials.first { $0.id == id && $0.isPassword } }?.id
        return RemoteDesktop(name: server.name, kind: kind, host: server.sshEnabled ? "localhost" : server.host,
                             username: kind.usesUsername ? server.username : nil, credentialID: password,
                             groupID: server.groupID, tunnelServerID: server.sshEnabled ? server.id : nil,
                             transport: server.sshEnabled ? .sshShared : .direct, serverID: server.id)
    }

    /// Turns SSH and each screen service of a saved server on or off. A screen turned on starts from `newService`;
    /// one turned off is removed (its settings with it); one left on is kept as it is. At least one must stay on.
    public func settingServices(of serverID: UUID, ssh: Bool,
                                screens: Set<ScreenService>) throws(VaultEditError) -> Vault {
        guard var server = servers.first(where: { $0.id == serverID }) else { throw .unknownServer }
        guard ssh || !screens.isEmpty else { throw .noService }
        var next = self
        if server.sshEnabled != ssh {
            server.sshEnabled = ssh
            next = try next.updatingServer(server)
        }
        for service in ScreenService.allCases {
            let existing = next.service(service, of: serverID)
            if screens.contains(service), existing == nil {
                next = try next.addingRemoteDesktop(next.newService(service, for: server))
            } else if !screens.contains(service), let existing {
                next = try next.deletingRemoteDesktops([existing.id])
            }
        }
        return next
    }

    /// Quick Connect "Save": `server` with `screens`. With `screensJoinSavedServers` (the user said so) and a saved
    /// server of the same host, the screens join that server instead and no new server is added (`added` nil).
    public func addingServer(_ server: Server, screens: Set<ScreenService>,
                             screensJoinSavedServers: Bool) throws(VaultEditError) -> (vault: Vault, added: Server?) {
        guard server.sshEnabled || !screens.isEmpty else { throw .noService }
        if screensJoinSavedServers, !screens.isEmpty, let existing = servers(matchingHost: server.host).first {
            let have = Set(services(of: existing.id).map { ScreenService($0.kind) })
            return (try settingServices(of: existing.id, ssh: existing.sshEnabled, screens: have.union(screens)), nil)
        }
        let added = try addingServer(server)
        return (try added.settingServices(of: server.id, ssh: server.sshEnabled, screens: screens), server)
    }

    /// Screens that reach their host through this server's SSH (its own, and others tunnelled through it): turning
    /// its SSH off would leave them without a way in, so the editor asks before (`switchingScreensToDirect`).
    public func screensRelyingOnSSH(of serverID: UUID) -> [RemoteDesktop] {
        remoteDesktops.filter { $0.tunnelServerID == serverID && $0.transport != .direct }
    }

    /// "Switch to direct": those screens connect straight to their host (a "localhost" one to the server's host).
    public func switchingScreensToDirect(of serverID: UUID) throws(VaultEditError) -> Vault {
        guard let server = servers.first(where: { $0.id == serverID }) else { throw .unknownServer }
        var next = self
        for var screen in screensRelyingOnSSH(of: serverID) {
            screen.transport = .direct
            screen.tunnelServerID = nil
            if Self.isLoopback(screen.host) { screen.host = server.host }
            next = try next.updatingRemoteDesktop(screen)
        }
        return next
    }

    /// Saved servers whose host is `host` (any case, trimmed): the question "Add RDP to <server>?" before saving a
    /// screen for a host that is already saved.
    public func servers(matchingHost host: String) -> [Server] {
        let wanted = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return servers.filter { $0.host.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Standalone screens that reach the same machine as a saved server (and the user did not keep separate):
    /// the same host straight, the server itself through its own SSH ("localhost"), or the server's host through
    /// the server's one jump host. One suggestion per screen, the first matching server.
    public var mergeSuggestions: [MergeSuggestion] {
        standaloneRemoteDesktops.filter { !$0.keepSeparate }.compactMap { desktop in
            servers.first { reachesSameMachine(desktop, $0) }.map { MergeSuggestion(desktop: desktop, server: $0) }
        }
    }

    /// Makes a standalone screen a service of `serverID`: its name and folder follow the server from now on.
    public func mergingRemoteDesktop(_ id: UUID, into serverID: UUID) throws(VaultEditError) -> Vault {
        guard var desktop = remoteDesktops.first(where: { $0.id == id }) else { throw .unknownRemoteDesktop }
        guard let server = servers.first(where: { $0.id == serverID }) else { throw .unknownServer }
        desktop.serverID = serverID
        desktop.keepSeparate = false
        desktop.name = server.name
        desktop.groupID = server.groupID
        return try updatingRemoteDesktop(desktop)
    }

    /// "Keep as a separate server": no more merge suggestions for this screen.
    public func keepingSeparate(_ id: UUID) throws(VaultEditError) -> Vault {
        guard var desktop = remoteDesktops.first(where: { $0.id == id }) else { throw .unknownRemoteDesktop }
        desktop.keepSeparate = true
        return try updatingRemoteDesktop(desktop)
    }

    private func reachesSameMachine(_ desktop: RemoteDesktop, _ server: Server) -> Bool {
        let sameHost = desktop.host.caseInsensitiveCompare(server.host) == .orderedSame
        switch desktop.transport {
        case .direct:
            return sameHost && server.jumpHosts.isEmpty
        case .sshShared, .sshSeparate:
            guard let tunnel = desktop.tunnelServerID else { return false }
            if tunnel == server.id { return sameHost || Self.isLoopback(desktop.host) }
            return sameHost && server.jumpHosts == [.server(tunnel)]
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }
}

extension RemoteDesktop {
    /// A server's screen after the server was edited: same name and folder, and its host when it goes straight
    /// there. Screens of other servers come back unchanged.
    func following(_ server: Server) -> RemoteDesktop {
        guard serverID == server.id else { return self }
        var copy = self
        copy.name = server.name
        copy.groupID = server.groupID
        if transport == .direct { copy.host = server.host }
        return copy
    }
}
