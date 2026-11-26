import Foundation
@testable import RSSHKit

/// Wraps a source to make writes fail once after `failAfter` bytes, or to pause reads until `gate` opens.
final class FaultySource: FileSource {
    let inner: MemoryFileSource
    let state = FaultState()
    var id: String { inner.id }
    var displayName: String { inner.displayName }
    var capabilities: FileCapabilities { inner.capabilities }
    var home: FilePath { inner.home }

    init(_ inner: MemoryFileSource) { self.inner = inner }

    func list(_ directory: FilePath) async throws -> [FileItem] { try await inner.list(directory) }
    func stat(_ path: FilePath) async throws -> FileItem { try await inner.stat(path) }
    func delete(_ path: FilePath) async throws { try await inner.delete(path) }
    func rename(_ path: FilePath, to newPath: FilePath) async throws { try await inner.rename(path, to: newPath) }
    func makeDirectory(_ path: FilePath) async throws { try await inner.makeDirectory(path) }

    func reader(for path: FilePath, from offset: Int64) async throws -> any FileReader {
        await state.noteReadOffset(offset)
        return GatedReader(inner: try await inner.reader(for: path, from: offset), state: state)
    }

    func writer(for path: FilePath, appendingAt offset: Int64) async throws -> any FileWriter {
        await state.noteWriteOffset(offset)
        return FailingWriter(inner: try await inner.writer(for: path, appendingAt: offset), state: state)
    }
}

actor FaultState {
    var failAfter: Int64?
    var written: Int64 = 0
    var readOffsets: [Int64] = []
    var writeOffsets: [Int64] = []
    var chunksRead = 0
    /// Reads past this many chunks wait until `open()`.
    var pauseAfterChunks: Int?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var pausedWatchers: [CheckedContinuation<Void, Never>] = []
    private(set) var isPaused = false

    func setFailAfter(_ bytes: Int64?) { failAfter = bytes; written = 0 }
    func setPause(afterChunks: Int?) { pauseAfterChunks = afterChunks }
    func noteReadOffset(_ offset: Int64) { readOffsets.append(offset) }
    func noteWriteOffset(_ offset: Int64) { writeOffsets.append(offset) }

    func beforeRead() async {
        chunksRead += 1
        guard let limit = pauseAfterChunks, chunksRead > limit else { return }
        isPaused = true
        pausedWatchers.forEach { $0.resume() }
        pausedWatchers = []
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Returns once a reader is parked at the gate.
    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pausedWatchers.append($0) }
    }

    func open() {
        pauseAfterChunks = nil
        waiting.forEach { $0.resume() }
        waiting = []
    }

    /// Throws once the byte budget is spent, then disarms itself.
    func beforeWrite(_ count: Int) throws {
        guard let limit = failAfter else { return }
        if written + Int64(count) > limit {
            failAfter = nil
            throw FileSourceError.failed("link dropped")
        }
        written += Int64(count)
    }
}

struct GatedReader: FileReader {
    let inner: any FileReader
    let state: FaultState
    func read(maxLength: Int) async throws -> Data {
        await state.beforeRead()
        return try await inner.read(maxLength: maxLength)
    }
    func close() async { await inner.close() }
}

struct FailingWriter: FileWriter {
    let inner: any FileWriter
    let state: FaultState
    func write(_ data: Data) async throws {
        try await state.beforeWrite(data.count)
        try await inner.write(data)
    }
    func finish() async throws { try await inner.finish() }
    func abort() async { await inner.abort() }
}
