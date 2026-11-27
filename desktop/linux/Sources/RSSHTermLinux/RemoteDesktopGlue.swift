import Foundation
import RSSHDesktopCore
import RSSHKit

/// Where the remote picture sits in the pane and how pane points map to screen pixels. Fit scales down (never up)
/// and centers; 1:1 draws from the top-left corner (the pane scrolls).
public struct ScreenGeometry: Equatable, Sendable {
    public enum Mode: String, Sendable { case fit, actualSize }

    public let scale: Double
    public let offsetX: Double
    public let offsetY: Double
    public let remoteWidth: Int
    public let remoteHeight: Int

    public init(remoteWidth: Int, remoteHeight: Int, viewWidth: Int, viewHeight: Int, mode: Mode) {
        self.remoteWidth = remoteWidth
        self.remoteHeight = remoteHeight
        guard mode == .fit, remoteWidth > 0, remoteHeight > 0, viewWidth > 0, viewHeight > 0 else {
            scale = 1
            offsetX = 0
            offsetY = 0
            return
        }
        let s = min(1, min(Double(viewWidth) / Double(remoteWidth), Double(viewHeight) / Double(remoteHeight)))
        scale = s
        offsetX = (Double(viewWidth) - Double(remoteWidth) * s) / 2
        offsetY = (Double(viewHeight) - Double(remoteHeight) * s) / 2
    }

    /// The screen pixel under a pane point; nil outside the picture.
    public func toRemote(x: Double, y: Double) -> (Int, Int)? {
        let rx = (x - offsetX) / scale, ry = (y - offsetY) / scale
        guard rx >= 0, ry >= 0, rx < Double(remoteWidth), ry < Double(remoteHeight) else { return nil }
        return (Int(rx), Int(ry))
    }
}

/// While a screen pane has focus every key goes to the remote side; Ctrl+Alt (pressed together, nothing else)
/// releases the keyboard, as GNOME Boxes and virt-viewer do.
public enum KeyGrab {
    static let controlKeys: Set<UInt32> = [0xffe3, 0xffe4]
    static let altKeys: Set<UInt32> = [0xffe9, 0xffea]

    public static func isReleaseChord(keyval: UInt32, state: UInt32) -> Bool {
        let ctrl = state & (1 << 2) != 0, alt = state & (1 << 3) != 0
        return (altKeys.contains(keyval) && ctrl) || (controlKeys.contains(keyval) && alt)
    }

    /// GDK keyvals are X11 keysyms, which is what RFB sends.
    public static func keysym(for keyval: UInt32) -> UInt32 { keyval }
}

/// The remote desktop editor's fields (new or edit), validated like the server editor.
public struct RemoteDesktopForm: Sendable {
    public enum Field: String, Sendable { case host, port, tunnelServer }

    public var name: String
    public private(set) var kind: RemoteDesktop.Kind
    public var host: String
    public var port: String
    public var transport: RemoteDesktop.Transport
    public var tunnelServerID: UUID?
    public var username: String
    public var credentialID: UUID?
    public var groupID: UUID?
    public var shareClipboard: Bool
    public var askEveryTime: Bool
    public var domain: String
    private let original: RemoteDesktop?
    public let servers: [Server]

    public init(desktop: RemoteDesktop?, servers: [Server], groupID: UUID? = nil) {
        original = desktop
        self.servers = servers
        name = desktop?.name ?? ""
        kind = desktop?.kind ?? .vnc
        host = desktop?.host ?? ""
        port = String(desktop?.port ?? RemoteDesktop.Kind.vnc.defaultPort)
        transport = desktop?.transport ?? (servers.isEmpty ? .direct : .sshShared)
        tunnelServerID = desktop?.tunnelServerID ?? servers.first?.id
        username = desktop?.username ?? ""
        credentialID = desktop?.credentialID
        self.groupID = desktop?.groupID ?? groupID
        shareClipboard = desktop?.shareClipboard ?? false
        askEveryTime = desktop?.askEveryTime ?? false
        domain = desktop?.domain ?? ""
    }

    /// Changes the kind; the port follows while it is empty or a kind's default (3389, 5900), as on iOS.
    public mutating func setKind(_ newKind: RemoteDesktop.Kind) {
        port = RemoteDesktop.Kind.port(port, switching: kind, to: newKind, typed: false)
        kind = newKind
    }

    public var issues: [Field] {
        var out: [Field] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty || host.contains(" ") { out.append(.host) }
        if Int(port).map({ !(1...65535).contains($0) }) ?? true { out.append(.port) }
        if transport != .direct, tunnelServerID.map({ id in !servers.contains { $0.id == id } }) ?? true { out.append(.tunnelServer) }
        return out
    }

    public static func message(_ field: Field) -> String {
        switch field {
        case .host: "Enter the screen's host as the SSH server sees it (localhost is the server itself)."
        case .port: "The port is a number from 1 to 65535."
        case .tunnelServer: "Choose the SSH server the screen is reached through, or Direct."
        }
    }

    /// Shown under the transport while it is Direct.
    public var directWarning: String? {
        guard transport == .direct else { return nil }
        return kind == .rdp ? "Direct: the RDP port must be exposed to this network; prefer an SSH server."
            : "Direct: VNC is not encrypted; the password challenge and every frame cross the network as they are."
    }

    public func makeDesktop(id: UUID) throws -> RemoteDesktop {
        guard issues.isEmpty else { throw ServerDraftError(issues: []) }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var d = original ?? RemoteDesktop(id: id, name: "", kind: kind, host: trimmedHost)
        d.id = id
        d.name = trimmedName.isEmpty ? trimmedHost : trimmedName
        d.kind = kind
        d.host = trimmedHost
        d.port = Int(port) ?? kind.defaultPort
        d.transport = transport
        d.tunnelServerID = transport == .direct ? nil : tunnelServerID
        d.username = kind.usesUsername && !username.isEmpty ? username : nil
        d.credentialID = credentialID
        d.groupID = groupID
        d.shareClipboard = shareClipboard
        d.askEveryTime = askEveryTime
        d.domain = kind == .rdp && !domain.isEmpty ? domain : nil
        return d
    }
}

extension SidebarRows {
    /// The sidebar with remote desktops after the servers of their folder; the search matches their name and host.
    public static func flatten(_ sections: [ServerListModel.Section], desktops: [RemoteDesktop], query: String) -> [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // A server's own screens open from its row (menu), so only screens saved on their own get rows.
        let shown = desktops.filter {
            $0.serverID == nil && (q.isEmpty || $0.name.lowercased().contains(q) || $0.host.lowercased().contains(q))
        }
        return sections.flatMap { section -> [Row] in
            let mine = shown.filter { $0.groupID == section.groupID }
            let count = section.servers.count + mine.count
            if !q.isEmpty, count == 0 { return [] }
            let header = Row.header(groupID: section.groupID, title: section.title, count: count, collapsed: section.isCollapsed)
            guard !section.isCollapsed else { return [header] }
            return [header] + section.servers.map { .server($0, groupID: section.groupID) }
                + mine.map { .desktop($0, groupID: section.groupID) }
        }
    }

    public static func subtitle(_ desktop: RemoteDesktop, servers: [Server]) -> String {
        let place = desktop.port == desktop.kind.defaultPort ? desktop.host : "\(desktop.host):\(desktop.port)"
        let kind = desktop.kind == .appleScreenSharing ? "Screen Sharing" : desktop.kind == .rdp ? "RDP" : "VNC"
        if desktop.transport == .direct {
            return "\(kind) · \(place) · direct" + (desktop.kind == .rdp ? "" : ", not encrypted")
        }
        let via = desktop.tunnelServerID.flatMap { id in servers.first { $0.id == id }?.name } ?? "a deleted server"
        return "\(kind) · \(place) via \(via)"
    }
}

/// What a screen pane shows while it has no picture: progress, or an error with its actions.
public struct ScreenCard: Equatable, Sendable {
    public enum Action: String, Sendable { case retry, edit, openTerminal, trustNew }

    public let title: String
    public let message: String
    public let actions: [Action]
    public let busy: Bool

    public init(title: String, message: String, actions: [Action], busy: Bool) {
        self.title = title
        self.message = message
        self.actions = actions
        self.busy = busy
    }

    public static func progress(_ step: String) -> ScreenCard {
        ScreenCard(title: step, message: "", actions: [], busy: true)
    }

    /// The tunnel or the screen failed; through an SSH server the message names it and offers its terminal.
    public static func failed(_ message: String, tunnelServer: String?) -> ScreenCard {
        ScreenCard(title: "Could not open the screen", message: tunnelServer.map { "\($0): \(message)" } ?? message,
                   actions: tunnelServer == nil ? [.retry, .edit] : [.retry, .edit, .openTerminal], busy: false)
    }

    public static func disconnected(_ reason: String?) -> ScreenCard {
        ScreenCard(title: "Disconnected", message: reason ?? "The screen was closed.", actions: [.retry], busy: false)
    }

    /// An RDP server presented another certificate than the pinned one: refused, loudly; "Trust New…" asks again.
    public static func certificateChanged(expected: String, presented: String) -> ScreenCard {
        ScreenCard(title: "The certificate changed",
                   message: "The screen presented a certificate that is not the one trusted before, so the connection was refused. "
                       + "Someone may be intercepting it, or the server was reinstalled. Trusted: \(expected). Presented now: \(presented).",
                   actions: [.trustNew, .edit], busy: false)
    }

    /// A Mac that offers only Apple's newer login types: on Linux the VNC password must be turned on there.
    public static let appleOnly = ScreenCard(
        title: "This Mac needs a VNC password",
        message: "It offers only Apple's newer login types. On the Mac: System Settings › General › Sharing › Screen Sharing › ⓘ › "
            + "“VNC viewers may control screen with password”, then Retry.",
        actions: [.retry, .edit], busy: false)
}

/// The desktop size an RDP session asks for: the pane's size, even, between 800×600 and 3840×2160.
public enum RDPDesktopSize {
    public static func requested(viewWidth: Int, viewHeight: Int) -> (Int, Int) {
        let w = min(max(viewWidth, 800), 3840) & ~1
        let h = min(max(viewHeight, 600), 2160) & ~1
        return (w, h)
    }
}

/// Dropping tab `from` onto tab `onto`: the index it moves to, nil when nothing moves.
public enum TabReorder {
    public static func destination(from: Int, onto: Int, count: Int) -> Int? {
        guard (0..<count).contains(from), (0..<count).contains(onto), from != onto else { return nil }
        return onto
    }
}
