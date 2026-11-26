import Foundation

/// A screen to open: a VNC server, a Mac's Screen Sharing or a Windows/xrdp RDP host. Secrets stay in the vault's
/// credentials (`credentialID`, a password); the connection normally runs through an SSH tunnel to a vault server.
public struct RemoteDesktop: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// RFB with a VNC password (or none): x11vnc, TigerVNC, a Raspberry Pi, a Mac with a VNC password set.
        case vnc
        /// RFB to a Mac with the macOS account (Apple Remote Desktop authentication).
        case appleScreenSharing
        /// Microsoft RDP: Windows, xrdp, gnome-remote-desktop.
        case rdp

        public var defaultPort: Int { self == .rdp ? 3389 : 5900 }
        /// VNC passwords have no user; macOS and RDP log in with an account.
        public var usesUsername: Bool { self != .vnc }

        public var title: String {
            switch self {
            case .vnc: "VNC"
            case .appleScreenSharing: "Apple Screen Sharing"
            case .rdp: "Remote Desktop (RDP)"
            }
        }
    }

    /// How the bytes travel.
    public enum Transport: String, Codable, CaseIterable, Sendable {
        /// A direct-tcpip channel on the tunnel server's SSH session the app already has (no second login); the
        /// session is opened like a terminal's when none is open.
        case sshShared
        /// Its own SSH connection to the tunnel server (same login, jump hosts and pinned host key).
        case sshSeparate
        /// Straight to host:port, no SSH: VNC is then unencrypted and the port exposed; the app asks first.
        case direct
    }

    /// iOS pointer: tap where to click, or move a cursor like a trackpad.
    public enum PointerMode: String, Codable, CaseIterable, Sendable {
        case touch, trackpad
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// The screen's address as the tunnel server sees it ("localhost" is the SSH server itself); without a tunnel,
    /// as this device sees it.
    public var host: String
    public var port: Int
    /// macOS or Windows account; nil for a VNC password.
    public var username: String?
    /// A password credential of the vault; nil asks at connect (or none for an open VNC server).
    public var credentialID: UUID?
    public var groupID: UUID?
    /// The vault server whose SSH connection carries the screen (with that server's own jump hosts); nil connects
    /// straight to `host`, which the app warns about: RFB is not encrypted.
    public var tunnelServerID: UUID?
    /// RDP domain (NetBIOS or DNS); nil for none.
    public var domain: String?
    /// Copy and paste between this device and the screen. Off unless the user turns it on for this entry: the
    /// other side would see everything copied here while the screen is open.
    public var shareClipboard: Bool
    public var transport: Transport
    public var pointerMode: PointerMode
    /// Show the login sheet on every connect even with a saved password (shared devices).
    public var askEveryTime: Bool
    /// RDP: the server certificate's SHA-256 fingerprint, pinned on first use like an SSH host key (lowercase).
    public var pinnedCertificate: String?
    /// The server this screen is a service of (listed and opened from that server, its name and folder follow it);
    /// nil for a screen saved on its own. Older builds ignore it and list the screen on its own, with every field.
    public var serverID: UUID?
    /// The user answered "Keep as a separate server" to merging it into a server with the same host.
    public var keepSeparate = false

    public init(id: UUID = UUID(), name: String, kind: Kind, host: String, port: Int? = nil,
                username: String? = nil, credentialID: UUID? = nil, groupID: UUID? = nil,
                tunnelServerID: UUID? = nil, domain: String? = nil, shareClipboard: Bool = false,
                transport: Transport? = nil, pointerMode: PointerMode = .trackpad, askEveryTime: Bool = false,
                serverID: UUID? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.credentialID = credentialID
        self.groupID = groupID
        self.tunnelServerID = tunnelServerID
        self.domain = domain
        self.shareClipboard = shareClipboard
        // With a tunnel server the default is its open session; without one there is nothing to tunnel through.
        self.transport = transport ?? (tunnelServerID == nil ? .direct : .sshShared)
        self.pointerMode = pointerMode
        self.askEveryTime = askEveryTime
        self.serverID = serverID
    }

    public var isTunnelled: Bool { transport != .direct }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, username, credentialID, groupID, tunnelServerID, domain, shareClipboard
        case transport, pointerMode, askEveryTime, pinnedCertificate, serverID, keepSeparate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  kind: kind, host: try c.decode(String.self, forKey: .host),
                  port: c.lenient(Int.self, .port),
                  username: c.lenient(String.self, .username),
                  credentialID: c.lenient(UUID.self, .credentialID),
                  groupID: c.lenient(UUID.self, .groupID),
                  tunnelServerID: c.lenient(UUID.self, .tunnelServerID),
                  domain: c.lenient(String.self, .domain),
                  shareClipboard: c.lenient(Bool.self, .shareClipboard) ?? false,
                  transport: Self.decodedTransport(c),
                  pointerMode: c.lenient(PointerMode.self, .pointerMode) ?? .trackpad,
                  askEveryTime: c.lenient(Bool.self, .askEveryTime) ?? false,
                  serverID: c.lenient(UUID.self, .serverID))
        pinnedCertificate = c.lenient(String.self, .pinnedCertificate)
        keepSeparate = c.lenient(Bool.self, .keepSeparate) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encodeIfPresent(credentialID, forKey: .credentialID)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encodeIfPresent(tunnelServerID, forKey: .tunnelServerID)
        try c.encodeIfPresent(domain, forKey: .domain)
        if shareClipboard { try c.encode(true, forKey: .shareClipboard) }
        try c.encode(transport, forKey: .transport)
        try c.encode(pointerMode, forKey: .pointerMode)
        if askEveryTime { try c.encode(true, forKey: .askEveryTime) }
        try c.encodeIfPresent(pinnedCertificate, forKey: .pinnedCertificate)
        try c.encodeIfPresent(serverID, forKey: .serverID)
        if keepSeparate { try c.encode(true, forKey: .keepSeparate) }
    }

    /// Absent: derived from the tunnel server. A transport this build does not know (a newer build's) falls back
    /// to `.direct`, which the app never uses without asking first.
    private static func decodedTransport(_ c: KeyedDecodingContainer<CodingKeys>) -> Transport? {
        guard c.contains(.transport) else { return nil }
        return c.lenient(Transport.self, .transport) ?? .direct
    }
}

// MARK: route

/// Where the remote-desktop client's bytes must arrive, as seen from the end of the route.
public struct RemoteDesktopTarget: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// How to reach a screen: through `sshServer` (a direct-tcpip forward to `target`), or straight to `target`.
public struct RemoteDesktopRoute: Hashable, Sendable {
    public enum Warning: Hashable, Sendable {
        /// No SSH tunnel: VNC's DES challenge and the framebuffer cross the network as they are.
        case notTunnelled
    }

    public var sshServer: Server?
    public var target: RemoteDesktopTarget
    public var warnings: [Warning]
    /// True: open the forward on the server's existing SSH session (opening it first if needed); false with a
    /// server: a connection of its own.
    public var reusesOpenSession: Bool = false
}

extension Vault {
    /// The route for `desktop`. The SSH server's own jump chain (if any) is the SSH layer's business: a tunnel
    /// through a server goes through its jump hosts like a shell does.
    public func route(for desktop: RemoteDesktop) throws(VaultEditError) -> RemoteDesktopRoute {
        let target = RemoteDesktopTarget(host: desktop.host, port: desktop.port)
        guard desktop.transport != .direct else {
            return RemoteDesktopRoute(sshServer: nil, target: target, warnings: [.notTunnelled])
        }
        guard let serverID = desktop.tunnelServerID else { throw .needsTunnelServer }
        guard let server = servers.first(where: { $0.id == serverID }) else { throw .unknownServer }
        return RemoteDesktopRoute(sshServer: server, target: target, warnings: [],
                                  reusesOpenSession: desktop.transport == .sshShared)
    }

    /// The remote desktops whose tunnel runs through this server.
    public func remoteDesktops(tunnelledThrough serverID: UUID) -> [RemoteDesktop] {
        remoteDesktops.filter { $0.tunnelServerID == serverID }
    }
}

// MARK: Screen Sharing.app

extension RemoteDesktop {
    /// `vnc://[user@]127.0.0.1:<port>` for macOS Screen Sharing.app, pointed at this device's end of the tunnel.
    /// Never carries the password (Screen Sharing asks, or takes it from the user's keychain). Nil for RDP and
    /// for port 5900 on this machine, which Screen Sharing takes for "this Mac" and refuses.
    public func screenSharingURL(localPort: Int) -> URL? {
        guard kind != .rdp, (1...65535).contains(localPort), localPort != 5900 else { return nil }
        var parts = URLComponents()
        parts.scheme = "vnc"
        parts.host = "127.0.0.1"
        parts.port = localPort
        if let username, !username.isEmpty {
            // URLComponents leaves "@" in a user alone; RFC 3986 userinfo needs it escaped.
            parts.percentEncodedUser = username.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved)
        }
        return parts.url
    }
}

extension CharacterSet {
    static let rfc3986Unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
