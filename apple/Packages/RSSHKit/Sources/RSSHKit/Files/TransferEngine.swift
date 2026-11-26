import Foundation

/// The transfer queue: runs up to `maxConcurrent` transfers at once, in the order they were queued, and reports
/// every change through `onChange` (the transfers screen). Cancel stops a transfer and removes its half-written
/// file; a failed transfer keeps its partial file, and `retry` continues it where both ends allow offsets.
public actor TransferEngine {
    public let chunkSize: Int
    public let maxConcurrent: Int
    private var resolver: ConflictResolver?
    private let onChange: @Sendable (TransferSnapshot) -> Void

    private var jobs: [UUID: TransferJob] = [:]
    private var order: [UUID] = []
    private var queued: [UUID] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var waiters: [UUID: [CheckedContinuation<TransferSnapshot, Never>]] = [:]

    public init(chunkSize: Int = 256 * 1024, maxConcurrent: Int = 2, resolver: ConflictResolver? = nil,
                onChange: @escaping @Sendable (TransferSnapshot) -> Void = { _ in }) {
        self.chunkSize = max(1, chunkSize)
        self.maxConcurrent = max(1, maxConcurrent)
        self.resolver = resolver
        self.onChange = onChange
    }

    /// Asked when a target name is taken and the policy is `.ask`. Without one, conflicts are skipped.
    public func setResolver(_ resolver: ConflictResolver?) { self.resolver = resolver }

    /// Queues a transfer and starts it when a slot is free.
    @discardableResult
    public func enqueue(_ request: TransferRequest) -> UUID {
        let id = UUID()
        let job = TransferJob(id: id, request: request, onChange: onChange)
        jobs[id] = job
        order.append(id)
        queued.append(id)
        onChange(TransferSnapshot(id: id, title: request.title, operation: request.operation))
        startNext()
        return id
    }

    /// Every transfer still known, oldest first.
    public func snapshots() async -> [TransferSnapshot] {
        var out: [TransferSnapshot] = []
        for id in order { if let job = jobs[id] { out.append(await job.snapshot) } }
        return out
    }

    public func snapshot(_ id: UUID) async -> TransferSnapshot? { await jobs[id]?.snapshot }

    public func cancel(_ id: UUID) async {
        if let index = queued.firstIndex(of: id) {
            queued.remove(at: index)
            await jobs[id]?.setState(.cancelled)
            await finish(id)
        } else {
            running[id]?.cancel()
        }
    }

    /// Runs a failed or cancelled transfer again; files already done are not copied twice.
    public func retry(_ id: UUID) async {
        guard let job = jobs[id], running[id] == nil, !queued.contains(id), await job.snapshot.state.isFinished,
              await job.snapshot.state != .completed
        else { return }
        await job.setState(.queued)
        queued.append(id)
        startNext()
    }

    /// Forgets finished transfers (the "Clear" button).
    public func clearFinished() async {
        for id in order {
            guard let job = jobs[id], running[id] == nil, !queued.contains(id) else { continue }
            if await job.snapshot.state.isFinished { jobs[id] = nil }
        }
        order.removeAll { jobs[$0] == nil }
    }

    /// Returns once the transfer has completed, failed or been cancelled.
    public func waitUntilFinished(_ id: UUID) async -> TransferSnapshot? {
        guard let job = jobs[id] else { return nil }
        let snapshot = await job.snapshot
        if snapshot.state.isFinished, running[id] == nil, !queued.contains(id) { return snapshot }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    // MARK: private

    private func startNext() {
        while running.count < maxConcurrent, !queued.isEmpty {
            let id = queued.removeFirst()
            guard let job = jobs[id] else { continue }
            let runner = TransferRunner(job: job, request: job.request, chunkSize: chunkSize, resolver: resolver)
            running[id] = Task { [weak self] in
                await job.setState(.running)
                let state: TransferSnapshot.State
                do {
                    try await runner.run()
                    state = .completed
                } catch is CancellationError {
                    state = .cancelled
                } catch TransferError.cancelledByUser {
                    state = .cancelled
                } catch {
                    state = Task.isCancelled ? .cancelled : .failed(error.userMessage)
                }
                await job.setState(state)
                await self?.ended(id)
            }
        }
    }

    private func ended(_ id: UUID) async {
        running[id] = nil
        await finish(id)
        startNext()
    }

    private func finish(_ id: UUID) async {
        guard let snapshot = await jobs[id]?.snapshot else { return }
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: snapshot) }
    }
}
