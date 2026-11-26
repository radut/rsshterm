import Foundation

/// One way to connect to a server, as the "How to connect" picker shows it: a button with a generic glyph and a
/// label. The glyphs are plain shapes, never a vendor's logo: SF Symbols on Apple platforms (`symbolName`), the same
/// shapes as bundled symbolic icons on Linux (`iconName`).
public enum ConnectService: String, CaseIterable, Hashable, Sendable {
    case ssh, rdp, vnc, screenSharing

    public init(_ screen: ScreenService) {
        switch screen {
        case .rdp: self = .rdp
        case .vnc: self = .vnc
        case .screenSharing: self = .screenSharing
        }
    }

    /// The screen service, nil for SSH.
    public var screen: ScreenService? {
        switch self {
        case .ssh: nil
        case .rdp: .rdp
        case .vnc: .vnc
        case .screenSharing: .screenSharing
        }
    }

    /// The button's label.
    public var label: String {
        switch self {
        case .ssh: "SSH"
        case .rdp: "RDP"
        case .vnc: "VNC"
        case .screenSharing: "Screen Sharing"
        }
    }

    /// One line under the label.
    public var detail: String {
        switch self {
        case .ssh: "Terminal"
        case .rdp: "Remote Desktop (Windows, xrdp)"
        case .vnc: "VNC password"
        case .screenSharing: "Mac account"
        }
    }

    /// SF Symbol: a terminal, a display, two overlapping screens, a Mac window.
    public var symbolName: String {
        switch self {
        case .ssh: "terminal"
        case .rdp: "display"
        case .vnc: "rectangle.on.rectangle"
        case .screenSharing: "macwindow"
        }
    }

    /// The bundled symbolic icon of the Linux app (desktop/linux/Resources/icons), the same shapes.
    public var iconName: String { "rssh-connect-\(rawValue)-symbolic" }
}

/// A button of the "How to connect" picker: SSH, or one of the server's screens.
public struct ConnectChoice: Hashable, Identifiable, Sendable {
    public var service: ConnectService
    /// The screen to open; nil for SSH.
    public var screenID: UUID?

    public init(service: ConnectService, screenID: UUID? = nil) {
        self.service = service
        self.screenID = screenID
    }

    public var id: String { screenID?.uuidString ?? service.rawValue }

    /// What opening it does.
    public var opening: ServerOpening { screenID.map(ServerOpening.screen) ?? .ssh }
}

extension Vault {
    /// The ways this server connects: SSH when it is on, then each screen (RDP, VNC, Screen Sharing). More than one:
    /// opening the server asks with the picker; one: it just opens.
    public func connectChoices(for server: Server) -> [ConnectChoice] {
        let ssh = server.sshEnabled ? [ConnectChoice(service: .ssh)] : []
        return ssh + services(of: server.id).map { ConnectChoice(service: ConnectService(ScreenService($0.kind)), screenID: $0.id) }
    }

    /// True when opening the server should ask how (two or more services).
    public func asksHowToConnect(_ server: Server) -> Bool { connectChoices(for: server).count > 1 }
}

extension DiscoveredHost {
    /// The glyph of a scan result: its screen (RDP, VNC, Screen Sharing), else SSH when a port answered as SSH.
    public var connectService: ConnectService? {
        if let screen = screenService { return ConnectService(screen) }
        return hasSSH ? .ssh : nil
    }
}
