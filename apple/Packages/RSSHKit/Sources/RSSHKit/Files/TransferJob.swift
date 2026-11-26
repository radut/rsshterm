import Foundation

/// The mutable side of one transfer: progress, the conflict policy (which "apply to all" changes), and what a retry
/// needs (targets already done, partial files and how far they got).
actor TransferJob {
    let request: TransferRequest
    private(set) var snapshot: TransferSnapshot
    private(set) var policy: ConflictPolicy
    /// Targets copied completely, skipped on a retry.
    private(set) var completed: Set<FilePath> = []
    /// Targets left half-written by a failure: bytes written so far, for a resume.
    private(set) var partial: [FilePath: Int64] = [:]
    private let onChange: @Sendable (TransferSnapshot) -> Void
    private var lastReport = ContinuousClock.now

    init(id: UUID, request: TransferRequest, onChange: @escaping @Sendable (TransferSnapshot) -> Void) {
        self.request = request
        self.policy = request.policy
        self.snapshot = TransferSnapshot(id: id, title: request.title, operation: request.operation)
        self.onChange = onChange
    }

    // MARK: progress

    func setState(_ state: TransferSnapshot.State) {
        snapshot.state = state
        if state == .running { snapshot.bytesDone = 0; snapshot.filesDone = 0; snapshot.skipped = 0 }
        if state.isFinished { snapshot.currentName = nil }
        publish()
    }

    func setTotals(bytes: Int64, files: Int) {
        snapshot.bytesTotal = bytes
        snapshot.filesTotal = files
        publish()
    }

    func starting(_ name: String) {
        snapshot.currentName = name
        publish()
    }

    /// Chunks are reported at most every 100 ms.
    func advance(by bytes: Int64) {
        snapshot.bytesDone += bytes
        let now = ContinuousClock.now
        if now - lastReport >= .milliseconds(100) { publish() }
    }

    func fileDone(_ target: FilePath) {
        completed.insert(target)
        partial[target] = nil
        snapshot.filesDone += 1
        publish()
    }

    /// A skipped item still counts its bytes, so the bar reaches the end.
    func fileSkipped(bytes: Int64, files: Int) {
        snapshot.skipped += files
        countDone(bytes: bytes, files: files)
    }

    /// Done without copying bytes: renamed in place, or completed by an earlier attempt.
    func countDone(bytes: Int64, files: Int) {
        snapshot.filesDone += files
        snapshot.bytesDone += bytes
        publish()
    }

    func setPolicy(_ newPolicy: ConflictPolicy) { policy = newPolicy }
    func recordPartial(_ target: FilePath, bytes: Int64) { partial[target] = bytes }
    func clearPartial(_ target: FilePath) { partial[target] = nil }

    private func publish() {
        lastReport = .now
        onChange(snapshot)
    }
}
