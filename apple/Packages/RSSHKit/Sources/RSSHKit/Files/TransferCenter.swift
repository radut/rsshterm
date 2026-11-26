import Foundation
import Observation
import RSSHKit

/// The transfer queue for the UI (iOS Transfers screen, desktop Transfers panel and status bar): snapshots to show,
/// and the one conflict question waiting for an answer ("Replace / Skip / Keep both", "apply to all"). Shared by
/// the iOS app and both desktop apps.
@MainActor @Observable
public final class TransferCenter {
    /// A conflict the engine is waiting on; answer with `answer(_:)`.
    public struct PendingConflict: Identifiable {
        public let id = UUID()
        public let conflict: TransferConflict
        fileprivate let reply: CheckedContinuation<ConflictAnswer, Never>
    }

    public private(set) var transfers: [TransferSnapshot] = []
    public private(set) var pendingConflict: PendingConflict?
    @ObservationIgnored private var waitingConflicts: [PendingConflict] = []
    @ObservationIgnored public private(set) var engine: TransferEngine!

    public init(maxConcurrent: Int = 2) {
        engine = TransferEngine(
            maxConcurrent: maxConcurrent,
            resolver: { [weak self] conflict in
                await withCheckedContinuation { reply in
                    Task { @MainActor in self?.ask(conflict, reply) ?? reply.resume(returning: ConflictAnswer(.skip)) }
                }
            },
            onChange: { [weak self] snapshot in
                Task { @MainActor in self?.update(snapshot) }
            })
    }

    public var activeCount: Int { transfers.filter { !$0.state.isFinished }.count }

    /// 0...1 over the running transfers whose size is known; nil when none is.
    public var overallFraction: Double? {
        let sized = transfers.filter { !$0.state.isFinished && $0.bytesTotal != nil }
        guard !sized.isEmpty else { return nil }
        let total = sized.reduce(Int64(0)) { $0 + ($1.bytesTotal ?? 0) }
        let done = sized.reduce(Int64(0)) { $0 + $1.bytesDone }
        return total == 0 ? 0 : min(1, Double(done) / Double(total))
    }

    @discardableResult
    public func start(_ request: TransferRequest) async -> UUID { await engine.enqueue(request) }

    public func cancel(_ id: UUID) { Task { await engine.cancel(id) } }
    public func retry(_ id: UUID) { Task { await engine.retry(id) } }

    /// Forgets finished transfers (the "Clear" button).
    public func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
        Task { await engine.clearFinished() }
    }

    /// Waits for the transfer to end and returns its last state (the commander refreshes panes then).
    public func waitUntilFinished(_ id: UUID) async -> TransferSnapshot? { await engine.waitUntilFinished(id) }

    public func answer(_ answer: ConflictAnswer) {
        pendingConflict?.reply.resume(returning: answer)
        pendingConflict = waitingConflicts.isEmpty ? nil : waitingConflicts.removeFirst()
    }

    private func ask(_ conflict: TransferConflict, _ reply: CheckedContinuation<ConflictAnswer, Never>) {
        let pending = PendingConflict(conflict: conflict, reply: reply)
        if pendingConflict == nil { pendingConflict = pending } else { waitingConflicts.append(pending) }
    }

    /// Snapshots can arrive out of order across tasks; a finished state is never replaced by a running one.
    private func update(_ snapshot: TransferSnapshot) {
        guard let index = transfers.firstIndex(where: { $0.id == snapshot.id }) else {
            transfers.append(snapshot)
            return
        }
        let current = transfers[index]
        if current.state.isFinished, !snapshot.state.isFinished, snapshot.state != .queued { return }
        if current.state == snapshot.state, snapshot.bytesDone < current.bytesDone { return }
        transfers[index] = snapshot
    }

    /// Screenshots and demos: a transfer shown as it would be at one moment.
    public func showForScreenshot(_ snapshot: TransferSnapshot) { update(snapshot) }
}
