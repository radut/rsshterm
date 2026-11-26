import Foundation

/// How a host showed it is there.
public enum LivenessCheck: String, CaseIterable, Comparable, Hashable, Sendable {
    /// An SSH port accepted the connection.
    case ssh
    /// It answered an ICMP echo.
    case ping
    /// A TCP port answered, open or refused (used when ping is not available, and for a refused SSH port).
    case tcp

    public var title: String {
        switch self {
        case .ssh: "SSH"
        case .ping: "ping"
        case .tcp: "TCP"
        }
    }

    public static func < (lhs: LivenessCheck, rhs: LivenessCheck) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum PingOutcome: Equatable, Sendable {
    case reply
    case noReply
    /// ICMP cannot be sent from here; the scanner falls back to TCP ports.
    case unavailable
}

/// ICMP echo. The app uses an unprivileged datagram ICMP socket; tests use a fake.
public protocol HostPinger: Sendable {
    func ping(host: String, timeout: Duration) async -> PingOutcome
}
