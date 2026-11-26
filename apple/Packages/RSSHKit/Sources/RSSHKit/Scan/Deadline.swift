import Foundation

/// Waits out a deadline. `Task.sleep` in the app; tests pass one that fires at once or never, so no test depends on
/// how fast the machine is.
public typealias DeadlineSleep = @Sendable (Duration) async throws -> Void

/// The real clock.
public let realDeadlineSleep: DeadlineSleep = { try await Task.sleep(for: $0) }

/// `operation`'s result, or `fallback` once `limit` has passed (`sleep` returned) or the caller is cancelled. The
/// operation is then cancelled but not waited for, so one that ignores cancellation (a blocking DNS lookup) cannot
/// hold the caller.
func withDeadline<T: Sendable>(_ limit: Duration, fallback: T, sleep: @escaping DeadlineSleep = realDeadlineSleep,
                               _ operation: @escaping @Sendable () async -> T) async -> T {
    let race = FirstResult<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            let work = Task { race.finish(await operation()) }
            let timer = Task {
                do {
                    try await sleep(limit)
                    race.finish(fallback)
                } catch {
                    // Cancelled: the operation (or the caller's cancellation) already decided.
                }
            }
            race.start(continuation, tasks: [work, timer])
        }
    } onCancel: {
        race.finish(fallback)
    }
}

/// Resumes a continuation with the first value it is given, then cancels the racing tasks.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var early: T?
    private var done = false

    func start(_ continuation: CheckedContinuation<T, Never>, tasks: [Task<Void, Never>]) {
        lock.lock()
        guard done, let early else {
            self.continuation = continuation
            self.tasks = tasks
            lock.unlock()
            return
        }
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation.resume(returning: early)
    }

    func finish(_ value: T) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let waiting = continuation, running = tasks
        continuation = nil
        tasks = []
        if waiting == nil { early = value }
        lock.unlock()
        running.forEach { $0.cancel() }
        waiting?.resume(returning: value)
    }
}
