import Foundation

/// How the desktop's ssh panes connect (Settings › SSH): keep-alive, connect timeout and reconnecting after a dropped
/// connection. The first two become `ssh -o` options. Agent forwarding is not here: it is a per-server choice with a
/// key scope (`AgentForwardingPlan`), which one forwarded agent socket cannot honour. Missing or bad values keep their
/// defaults, so an older or newer file still loads.
public struct SSHConnectionOptions: Codable, Equatable, Sendable {
    public static let keepAliveRange = 0...600
    public static let connectTimeoutRange = 0...300

    /// Seconds between keep-alive probes (ServerAliveInterval, 3 missed = dropped); 0 = off.
    public var keepAliveSeconds = 30
    /// Seconds to wait for the TCP connection (ConnectTimeout); 0 = ssh's default.
    public var connectTimeoutSeconds = 15
    /// A pane whose connection drops (ssh status 255) connects again by itself (`ReconnectPolicy`).
    public var autoReconnect = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SSHConnectionOptions()
        keepAliveSeconds = (try? c.decodeIfPresent(Int.self, forKey: .keepAliveSeconds)) ?? d.keepAliveSeconds
        connectTimeoutSeconds = (try? c.decodeIfPresent(Int.self, forKey: .connectTimeoutSeconds)) ?? d.connectTimeoutSeconds
        autoReconnect = (try? c.decodeIfPresent(Bool.self, forKey: .autoReconnect)) ?? d.autoReconnect
    }

    public func clamped() -> SSHConnectionOptions {
        var o = self
        o.keepAliveSeconds = min(max(keepAliveSeconds, Self.keepAliveRange.lowerBound), Self.keepAliveRange.upperBound)
        o.connectTimeoutSeconds = min(max(connectTimeoutSeconds, Self.connectTimeoutRange.lowerBound),
                                      Self.connectTimeoutRange.upperBound)
        return o
    }

    /// The `-o` options for `ssh`, before the host alias.
    public var sshArguments: [String] {
        let o = clamped()
        var options: [String] = []
        if o.keepAliveSeconds > 0 { options += ["ServerAliveInterval=\(o.keepAliveSeconds)", "ServerAliveCountMax=3"] }
        if o.connectTimeoutSeconds > 0 { options.append("ConnectTimeout=\(o.connectTimeoutSeconds)") }
        return options.flatMap { ["-o", $0] }
    }
}

/// When an ssh pane that ended connects again: only a lost connection (ssh's own status 255, not a refused login),
/// after 1, 2, 5, 10, 20, 30 seconds, then it gives up. A connection that lasted a minute starts the count again.
public struct ReconnectPolicy: Sendable {
    public let delays: [Int] = [1, 2, 5, 10, 20, 30]
    public var maximumAttempts: Int { delays.count }
    /// Seconds a connection must have lasted for the next drop to count as a fresh one.
    public let stableAfter: TimeInterval = 60

    public init() {}

    /// Seconds to wait before attempt number `attempt` (0-based), or nil to leave the pane ended.
    public func delay(exitStatus: Int32, refusedLogin: Bool, attempt: Int, enabled: Bool) -> Int? {
        guard enabled, exitStatus == 255, !refusedLogin, delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }

    /// The attempt number for the next drop, given the previous one and how long the connection lasted.
    public func attemptAfter(previous: Int, connectedFor seconds: TimeInterval) -> Int {
        seconds >= stableAfter ? 0 : previous + 1
    }
}
