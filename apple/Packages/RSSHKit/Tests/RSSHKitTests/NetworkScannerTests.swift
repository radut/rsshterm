import Foundation
import Testing
@testable import RSSHKit

// No test here reads the clock or sleeps for real: deadlines are injected and either fire at once or never fire, and
// "hangs" are suspensions that end only when the task is cancelled.

/// A deadline that never passes: the operation always decides (or the caller's cancellation does).
private let neverFires: DeadlineSleep = { _ in
    await suspendUntilCancelled()
    throw CancellationError()
}

/// A deadline that has already passed.
private let firesAtOnce: DeadlineSleep = { _ in }

/// Suspends until the current task is cancelled: iterating a stream that never yields ends on cancellation.
private func suspendUntilCancelled() async {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    for await _ in stream {}
    withExtendedLifetime(continuation) {}
}

/// Counts probes. With `gate`, the first `gate` probes wait until that many run at once, which proves the scanner
/// does run them concurrently without depending on timing.
private actor ProbeLog {
    private(set) var running = 0
    private(set) var peak = 0
    private(set) var started = 0
    private let gate: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(gate: Int = 0) { self.gate = gate }

    func begin() async {
        running += 1
        started += 1
        peak = max(peak, running)
        let ready = startWaiters.filter { $0.count <= started }
        startWaiters.removeAll { $0.count <= started }
        ready.forEach { $0.continuation.resume() }
        guard started <= gate else { return }
        if running >= gate {
            let released = waiting
            waiting = []
            released.forEach { $0.resume() }
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    func end() { running -= 1 }

    /// Returns once `count` probes have started.
    func waitForStarted(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }
}

/// Answers from a table at once; hosts not in it never answer until cancelled.
private struct FakeProbe: PortProbe {
    let answers: [String: ProbeOutcome]
    let log: ProbeLog

    init(answers: [String: ProbeOutcome], gate: Int = 0) {
        self.answers = answers
        log = ProbeLog(gate: gate)
    }

    func probe(host: String, port: Int, timeout: Duration) async -> ProbeOutcome {
        await log.begin()
        let answer = answers["\(host):\(port)"]
        if answer == nil { await suspendUntilCancelled() }
        await log.end()
        return answer ?? .closed
    }
}

private struct FakePinger: HostPinger {
    let replies: Set<String>
    var available = true
    func ping(host: String, timeout: Duration) async -> PingOutcome {
        guard available else { return .unavailable }
        return replies.contains(host) ? .reply : .noReply
    }
}

private struct FakeResolver: HostNameResolver {
    func name(for host: String) async -> String? { host == "192.0.2.5" ? "box.example.com" : nil }
}

@Suite struct NetworkScannerTests {
    private func collect(_ stream: AsyncStream<ScanEvent>) async -> (found: [DiscoveredHost], last: ScanProgress?) {
        var found: [DiscoveredHost] = [], last: ScanProgress?
        for await event in stream {
            switch event {
            case .found(let host): found.append(host)
            case .progress(let progress): last = progress
            }
        }
        return (found, last)
    }

    @Test func findsOpenPortsWithBannerAndName() async throws {
        let answers: [String: ProbeOutcome] = [
            "192.0.2.5:22": .open(firstLine: "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13\r"),
            "192.0.2.6:2222": .open(firstLine: nil),
        ]
        // Every other port is closed; web ports too, for the no-ping fallback.
        let closed = (4...8).flatMap { host in [22, 2222, 80, 443].map { "192.0.2.\(host):\($0)" } }
        let probe = FakeProbe(answers: Dictionary(uniqueKeysWithValues: closed.map { ($0, .closed) })
            .merging(answers) { $1 })
        let scanner = NetworkScanner(probe: probe, resolver: FakeResolver(), concurrency: 8, deadlineSleep: neverFires)
        let range = try NetworkRange(parsing: "192.0.2.4-8")
        let (found, last) = await collect(scanner.scan(range, ports: [22, 2222]))
        let sorted = found.sorted(by: DiscoveredHost.listOrder)
        #expect(sorted.map(\.id) == ["192.0.2.5:22", "192.0.2.6:2222"])
        #expect(sorted[0].dnsName == "box.example.com")
        #expect(sorted[0].banner?.osHint == "Ubuntu")
        #expect(sorted[1].banner == nil)
        #expect(last == ScanProgress(done: 5, total: 5))
        #expect(sorted[0].answered == [.ssh])
    }

    @Test func pingAndRefusedPortsCountAsAlive() async throws {
        let probe = FakeProbe(answers: [
            "192.0.2.1:22": .open(firstLine: "SSH-2.0-OpenSSH_9.7"),
            "192.0.2.2:22": .refused,
            "192.0.2.3:22": .closed,
            "192.0.2.4:22": .closed,
        ])
        let scanner = NetworkScanner(probe: probe, pinger: FakePinger(replies: ["192.0.2.1", "192.0.2.3"]),
                                     concurrency: 8, deadlineSleep: neverFires)
        let (found, last) = await collect(scanner.scan(try NetworkRange(parsing: "192.0.2.1-4"), ports: [22]))
        let byHost = Dictionary(uniqueKeysWithValues: found.map { ($0.host, $0) })
        #expect(byHost["192.0.2.1"]?.answered == [.ssh, .ping])
        #expect(byHost["192.0.2.2"]?.answered == [.tcp])
        #expect(byHost["192.0.2.3"]?.answered == [.ping])
        #expect(byHost["192.0.2.3"]?.hasSSH == false)
        #expect(byHost["192.0.2.3"]?.port == 22)
        #expect(byHost["192.0.2.4"] == nil)
        #expect(last == ScanProgress(done: 4, total: 4))
    }

    @Test func withoutPingTriesWebPortsOnlyForSilentHosts() async throws {
        let probe = FakeProbe(answers: [
            "192.0.2.1:22": .closed, "192.0.2.1:80": .closed, "192.0.2.1:443": .refused,
            "192.0.2.2:22": .closed, "192.0.2.2:80": .closed, "192.0.2.2:443": .closed,
            "192.0.2.3:22": .open(firstLine: nil),
        ])
        let scanner = NetworkScanner(probe: probe, pinger: FakePinger(replies: [], available: false), concurrency: 8,
                                     deadlineSleep: neverFires)
        let (found, _) = await collect(scanner.scan(try NetworkRange(parsing: "192.0.2.1-3"), ports: [22]))
        let byHost = Dictionary(uniqueKeysWithValues: found.map { ($0.host, $0) })
        #expect(byHost["192.0.2.1"]?.answered == [.tcp])
        #expect(byHost["192.0.2.2"] == nil)
        #expect(byHost["192.0.2.3"]?.answered == [.ssh])
        // .3 answered on SSH, so its web ports were never tried: 3 + 2 + 2 probes.
        #expect(await probe.log.started == 7)
    }

    @Test func pingThatNeverAnswersDoesNotFallBack() async throws {
        let probe = FakeProbe(answers: ["192.0.2.1:22": .closed])
        let scanner = NetworkScanner(probe: probe, pinger: FakePinger(replies: []), deadlineSleep: neverFires)
        let (found, _) = await collect(scanner.scan(try NetworkRange(parsing: "192.0.2.1"), ports: [22]))
        #expect(found.isEmpty)
        #expect(await probe.log.started == 1)
    }

    @Test func runsExactlyTheConcurrencyLimitAtOnce() async throws {
        let answers = Dictionary(uniqueKeysWithValues: (1...40).map { ("192.0.2.\($0):22", ProbeOutcome.closed) })
        // The first 4 probes wait for each other: the scan only finishes if 4 really run at once.
        let probe = FakeProbe(answers: answers, gate: 4)
        let scanner = NetworkScanner(probe: probe, pinger: FakePinger(replies: []), concurrency: 4,
                                     deadlineSleep: neverFires)
        let (_, last) = await collect(scanner.scan(try NetworkRange(parsing: "192.0.2.1-40"), ports: [22]))
        #expect(await probe.log.peak == 4)
        #expect(await probe.log.started == 40)
        #expect(last == ScanProgress(done: 40, total: 40))
    }

    @Test func silentHostsEndAtTheDeadline() async throws {
        // Probes never answer; only the (already passed) deadline can end them.
        let probe = FakeProbe(answers: [:])
        let scanner = NetworkScanner(probe: probe, concurrency: 16, deadlineSleep: firesAtOnce)
        let (found, last) = await collect(scanner.scan(try NetworkRange(parsing: "192.0.2.1-16"), ports: [22]))
        #expect(found.isEmpty)
        #expect(last == ScanProgress(done: 16, total: 16))
    }

    @Test func stoppingEndsTheScanEarly() async throws {
        let probe = FakeProbe(answers: [:])
        let scanner = NetworkScanner(probe: probe, concurrency: 2, deadlineSleep: neverFires)
        let range = try NetworkRange(parsing: "198.51.100.0/24")
        let task = Task { await collect(scanner.scan(range, ports: [22])) }
        // Both slots are busy with probes that only end when cancelled; then stop.
        await probe.log.waitForStarted(2)
        task.cancel()
        let (found, last) = await task.value
        #expect(found.isEmpty)
        #expect((last?.done ?? 0) <= 2)
        // The 2 hosts in flight may still try their 2 fallback web ports while winding down; no new host starts.
        #expect(await probe.log.started <= 6)
    }
}

/// Lets a test hold an operation that ignores cancellation, then let it go.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Never>?
    private var released: Int?

    func wait() async -> Int {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let released {
                lock.unlock()
                continuation.resume(returning: released)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release(_ value: Int) {
        lock.lock()
        released = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}

@Suite struct DeadlineTests {
    @Test func returnsTheResultWhenTheOperationFinishes() async {
        #expect(await withDeadline(.seconds(1), fallback: 0, sleep: neverFires) { 7 } == 7)
    }

    @Test func returnsTheFallbackWhenTheDeadlinePasses() async {
        #expect(await withDeadline(.seconds(1), fallback: 0, sleep: firesAtOnce) {
            await suspendUntilCancelled()
            return 7
        } == 0)
    }

    @Test func doesNotWaitForAnOperationThatIgnoresCancellation() async {
        let latch = Latch()
        // Returns while the operation is still held: it ignores the cancellation the deadline sends.
        #expect(await withDeadline(.seconds(1), fallback: 0, sleep: firesAtOnce) { await latch.wait() } == 0)
        latch.release(7)
    }

    @Test func cancellingTheCallerReturnsTheFallback() async {
        let latch = Latch()
        let task = Task { await withDeadline(.seconds(1), fallback: -1, sleep: neverFires) { await latch.wait() } }
        task.cancel()
        #expect(await task.value == -1)
        latch.release(7)
    }
}
