import Foundation

/// What a TCP probe of one port saw.
public enum ProbeOutcome: Equatable, Sendable {
    /// No answer, or no connection within the time allowed.
    case closed
    /// The host answered with a reset: it is there, the port is not open.
    case refused
    /// Connected; `firstLine` is what the server sent first, nil when it sent nothing in time.
    case open(firstLine: String?)
}

/// Connects to one port and reads the first line. The app uses Network.framework; tests use a fake.
/// Implementations return by `timeout` and stop early when their task is cancelled.
public protocol PortProbe: Sendable {
    func probe(host: String, port: Int, timeout: Duration) async -> ProbeOutcome
}

/// Reverse DNS. nil when there is no name.
public protocol HostNameResolver: Sendable {
    func name(for host: String) async -> String?
}

public struct ScanProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
}

public enum ScanEvent: Equatable, Sendable {
    case found(DiscoveredHost)
    case progress(ScanProgress)
}

/// Checks every host of a range, `concurrency` hosts at a time, and streams what it finds. A host is found when one of
/// its SSH ports accepts a connection, when it answers ping, or when a TCP port answers at all. Ending the stream's
/// iteration (or cancelling the task that reads it) stops the scan.
public struct NetworkScanner: Sendable {
    public static let defaultConcurrency = 64
    public static let defaultTimeout: Duration = .milliseconds(800)
    /// Tried when ping is not available: a reset or an accept from either shows the host is there.
    public static let fallbackPorts = [80, 443]

    let probe: any PortProbe
    let pinger: (any HostPinger)?
    let resolver: (any HostNameResolver)?
    let concurrency: Int
    let timeout: Duration
    let sleep: DeadlineSleep

    public init(probe: any PortProbe, pinger: (any HostPinger)? = nil, resolver: (any HostNameResolver)? = nil,
                concurrency: Int = defaultConcurrency, timeout: Duration = defaultTimeout,
                deadlineSleep: @escaping DeadlineSleep = realDeadlineSleep) {
        self.probe = probe
        self.pinger = pinger
        self.resolver = resolver
        self.concurrency = max(1, concurrency)
        self.timeout = timeout
        sleep = deadlineSleep
    }

    public func scan(_ range: NetworkRange, ports: [Int]) -> AsyncStream<ScanEvent> {
        let hosts = range.hosts.map(\.description), ports = ports.isEmpty ? [22] : ports
        return AsyncStream { continuation in
            let task = Task {
                await run(hosts, ports: ports) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ hosts: [String], ports: [Int], emit: @Sendable (ScanEvent) -> Void) async {
        emit(.progress(ScanProgress(done: 0, total: hosts.count)))
        await withTaskGroup(of: [DiscoveredHost].self) { group in
            var pending = hosts.makeIterator()
            for _ in 0..<concurrency {
                guard let host = pending.next() else { break }
                group.addTask { await check(host, ports: ports) }
            }
            var done = 0
            while let found = await group.next() {
                done += 1
                found.forEach { emit(.found($0)) }
                emit(.progress(ScanProgress(done: done, total: hosts.count)))
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let host = pending.next() { group.addTask { await check(host, ports: ports) } }
            }
        }
    }

    /// One entry per open SSH port; else one entry when ping or TCP shows the host is there; else none.
    private func check(_ host: String, ports: [Int]) async -> [DiscoveredHost] {
        async let pinged = ping(host)
        let outcomes = await probeAll(host, ports: ports)
        var alive = Set<LivenessCheck>()
        switch await pinged {
        case .reply: alive.insert(.ping)
        case .noReply: break
        case .unavailable:
            let sshAnswered = outcomes.contains { $0.outcome != .closed }
            if !sshAnswered, await probeAll(host, ports: Self.fallbackPorts).contains(where: { $0.outcome != .closed }) {
                alive.insert(.tcp)
            }
        }
        if outcomes.contains(where: { $0.outcome == .refused }) { alive.insert(.tcp) }
        guard !Task.isCancelled else { return [] }
        let open = outcomes.compactMap { item -> (port: Int, line: String?)? in
            guard case .open(let line) = item.outcome else { return nil }
            return (item.port, line)
        }
        guard !open.isEmpty || !alive.isEmpty else { return [] }
        let name = await reverseName(host)
        if open.isEmpty {
            return [DiscoveredHost(host: host, port: ports[0], dnsName: name, answered: alive)]
        }
        return open.map {
            DiscoveredHost(host: host, port: $0.port, dnsName: name, banner: $0.line.flatMap(SSHBanner.init(line:)),
                           answered: alive.union([.ssh]), rfbVersion: $0.line.flatMap(Self.rfbGreeting))
        }
    }

    /// "RFB 003.889" from the first line a port sent, nil when it is not an RFB greeting. The same probe that reads
    /// an SSH banner tells VNC from a Mac's Screen Sharing: no second connection.
    static func rfbGreeting(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("RFB ") ? String(trimmed.prefix(11)) : nil
    }

    private func probeAll(_ host: String, ports: [Int]) async -> [(port: Int, outcome: ProbeOutcome)] {
        let probe = self.probe, timeout = self.timeout, sleep = self.sleep
        return await withTaskGroup(of: (port: Int, outcome: ProbeOutcome).self) { group in
            for port in ports {
                group.addTask {
                    // The probe should keep to `timeout`; the grace is a backstop for one that does not.
                    let outcome = await withDeadline(timeout + .milliseconds(250), fallback: .closed, sleep: sleep) {
                        await probe.probe(host: host, port: port, timeout: timeout)
                    }
                    return (port, outcome)
                }
            }
            var results: [(port: Int, outcome: ProbeOutcome)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.port < $1.port }
        }
    }

    private func ping(_ host: String) async -> PingOutcome {
        guard let pinger else { return .unavailable }
        let timeout = self.timeout
        return await withDeadline(timeout + .milliseconds(250), fallback: .noReply, sleep: sleep) {
            await pinger.ping(host: host, timeout: timeout)
        }
    }

    private func reverseName(_ host: String) async -> String? {
        guard let resolver else { return nil }
        return await withDeadline(timeout, fallback: nil, sleep: sleep) { await resolver.name(for: host) }
    }
}
