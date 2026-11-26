import Foundation

/// One SSH server a scan or a Bonjour browse found.
public struct DiscoveredHost: Hashable, Identifiable, Sendable {
    public var host: String
    public var port: Int
    /// Reverse DNS name, when it answered in time.
    public var dnsName: String?
    /// The Bonjour service name ("Office NAS"), when the host advertises one.
    public var serviceName: String?
    public var banner: SSHBanner?
    /// The RFB greeting a screen port sent ("RFB 003.889" from a Mac's Screen Sharing), nil for anything else.
    public var rfbVersion: String?
    /// What answered. A host without `.ssh` was found by ping or TCP only; `port` is then the first SSH port tried.
    public var answered: Set<LivenessCheck>

    public init(host: String, port: Int = 22, dnsName: String? = nil, serviceName: String? = nil, banner: SSHBanner? = nil,
                answered: Set<LivenessCheck> = [.ssh], rfbVersion: String? = nil) {
        self.host = host
        self.port = port
        self.dnsName = dnsName
        self.serviceName = serviceName
        self.banner = banner
        self.answered = answered
        self.rfbVersion = rfbVersion
    }

    /// The screen behind the open port (RDP, VNC or Screen Sharing by the RFB greeting), nil for SSH or none.
    public var screenService: ScreenService? {
        guard hasSSH || answered.contains(.tcp) else { return nil }
        return ScreenService(port: port, rfbVersion: rfbVersion)
    }

    public var hasSSH: Bool { answered.contains(.ssh) }

    public var id: String { "\(host):\(port)" }

    /// True when the open port is a screen's (3389 RDP, 5900 VNC or Screen Sharing), not SSH.
    public var isScreen: Bool { screenService != nil }

    /// What answered, for the results list: "SSH", "Remote Desktop (RDP)", "VNC", "Apple Screen Sharing",
    /// "port 8080", or "ping only" for a host found without an open port.
    public var serviceTitle: String {
        if let screen = screenService { return screen.title }
        if hasSSH { return port == 22 || banner != nil ? "SSH" : "port \(port)" }
        return answered.contains(.tcp) ? "port \(port)" : "ping only"
    }

    /// The name a saved server gets: the DNS name, else the Bonjour name, else the address (with a port other than 22).
    public var suggestedName: String {
        if let dnsName, !dnsName.isEmpty { return dnsName }
        if let serviceName, !serviceName.isEmpty { return serviceName }
        return port == 22 ? host : "\(host):\(port)"
    }

    /// Fills what this one lacks from `other` (the same host and port, found another way).
    public func merged(with other: DiscoveredHost) -> DiscoveredHost {
        DiscoveredHost(host: host, port: port, dnsName: dnsName ?? other.dnsName,
                       serviceName: serviceName ?? other.serviceName, banner: banner ?? other.banner,
                       answered: answered.union(other.answered), rfbVersion: rfbVersion ?? other.rfbVersion)
    }
}

extension [DiscoveredHost] {
    /// Adds `found`, or merges it into the entry with the same host and port. Keeps IPv4 order (then port), names
    /// after addresses.
    public func adding(_ found: DiscoveredHost) -> [DiscoveredHost] {
        var copy = self
        if let index = copy.firstIndex(where: { $0.id == found.id }) {
            copy[index] = copy[index].merged(with: found)
        } else {
            copy.append(found)
        }
        return copy.sorted(by: DiscoveredHost.listOrder)
    }
}

extension DiscoveredHost {
    static func listOrder(_ lhs: DiscoveredHost, _ rhs: DiscoveredHost) -> Bool {
        switch (IPv4(lhs.host), IPv4(rhs.host)) {
        case let (left?, right?): left == right ? lhs.port < rhs.port : left < right
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs.host == rhs.host ? lhs.port < rhs.port : lhs.host < rhs.host
        }
    }
}
