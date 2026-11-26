import Foundation
import Testing
@testable import RSSHKit

@Suite struct TransferEngineTests {
    static let bytes = Data((0..<1000).map { UInt8($0 % 251) })

    func twoSources() async -> (MemoryFileSource, MemoryFileSource) {
        let left = MemoryFileSource(id: "left", displayName: "Left")
        let right = MemoryFileSource(id: "right", displayName: "Right")
        await left.seed(FilePath("/src/big.bin"), Self.bytes)
        await left.seed(FilePath("/src/tree/a.txt"), Data("a".utf8))
        await left.seed(FilePath("/src/tree/sub/b.txt"), Data("bb".utf8))
        await left.seedDirectory(FilePath("/src/tree/empty"))
        await right.seedDirectory(FilePath("/dst"))
        return (left, right)
    }

    func run(_ engine: TransferEngine, _ request: TransferRequest) async -> TransferSnapshot? {
        let id = await engine.enqueue(request)
        return await engine.waitUntilFinished(id)
    }

    @Test func copiesFilesAndTreesBetweenSourcesInChunks() async throws {
        let (left, right) = await twoSources()
        let engine = TransferEngine(chunkSize: 64)
        let done = await run(engine, TransferRequest(source: left, items: [FilePath("/src/big.bin"), FilePath("/src/tree")],
                                                     destination: right, destinationDirectory: FilePath("/dst"), operation: .copy))
        #expect(done?.state == .completed)
        #expect(done?.bytesDone == 1003 && done?.bytesTotal == 1003)
        #expect(done?.filesDone == 3 && done?.filesTotal == 3)
        #expect(await right.contents(of: FilePath("/dst/big.bin")) == Self.bytes)
        #expect(await right.contents(of: FilePath("/dst/tree/sub/b.txt")) == Data("bb".utf8))
        #expect(try await right.stat(FilePath("/dst/tree/empty")).isDirectory)
        #expect(await left.contents(of: FilePath("/src/big.bin")) == Self.bytes)
    }

    @Test func moveDeletesTheSourceAfterVerifying() async throws {
        let (left, right) = await twoSources()
        let engine = TransferEngine(chunkSize: 100)
        let done = await run(engine, TransferRequest(source: left, items: [FilePath("/src/tree")], destination: right,
                                                     destinationDirectory: FilePath("/dst"), operation: .move))
        #expect(done?.state == .completed)
        #expect(await right.contents(of: FilePath("/dst/tree/a.txt")) == Data("a".utf8))
        #expect(try await left.statIfExists(FilePath("/src/tree")) == nil)
    }

    @Test func moveWithinOneSourceRenames() async throws {
        let (left, _) = await twoSources()
        let faulty = FaultySource(left)
        let engine = TransferEngine()
        await left.seedDirectory(FilePath("/other"))
        let done = await run(engine, TransferRequest(source: faulty, items: [FilePath("/src/big.bin")], destination: faulty,
                                                     destinationDirectory: FilePath("/other"), operation: .move))
        #expect(done?.state == .completed)
        #expect(await left.contents(of: FilePath("/other/big.bin")) == Self.bytes)
        #expect(await faulty.state.readOffsets.isEmpty)   // no bytes were copied
    }

    @Test func refusesAFolderIntoItself() async {
        let (left, _) = await twoSources()
        let done = await run(TransferEngine(), TransferRequest(source: left, items: [FilePath("/src")], destination: left,
                                                               destinationDirectory: FilePath("/src/tree"), operation: .copy))
        #expect(done?.state == .failed(TransferError.intoItself(FilePath("/src")).userMessage))
    }

    @Test func copyOntoItselfMakesANumberedDuplicate() async throws {
        let (left, _) = await twoSources()
        let done = await run(TransferEngine(), TransferRequest(source: left, items: [FilePath("/src/tree/a.txt")],
                                                               destination: left, destinationDirectory: FilePath("/src/tree"),
                                                               operation: .copy))
        #expect(done?.state == .completed)
        #expect(await left.contents(of: FilePath("/src/tree/a (1).txt")) == Data("a".utf8))
    }

    @Test(arguments: [ConflictPolicy.overwrite, .skip, .rename])
    func conflictPolicies(policy: ConflictPolicy) async throws {
        let (left, right) = await twoSources()
        await right.seed(FilePath("/dst/big.bin"), Data("old".utf8))
        let done = await run(TransferEngine(), TransferRequest(source: left, items: [FilePath("/src/big.bin")], destination: right,
                                                               destinationDirectory: FilePath("/dst"), operation: .copy, policy: policy))
        #expect(done?.state == .completed)
        let current = await right.contents(of: FilePath("/dst/big.bin"))
        switch policy {
        case .overwrite: #expect(current == Self.bytes)
        case .skip:
            #expect(current == Data("old".utf8))
            #expect(done?.skipped == 1 && done?.fraction == 1)
        case .rename:
            #expect(current == Data("old".utf8))
            #expect(await right.contents(of: FilePath("/dst/big (1).bin")) == Self.bytes)
        case .ask: break
        }
    }

    @Test func askUsesTheResolverAndApplyToAll() async throws {
        let (left, right) = await twoSources()
        await right.seed(FilePath("/dst/tree/a.txt"), Data("old".utf8))
        await right.seed(FilePath("/dst/tree/sub/b.txt"), Data("old".utf8))
        let asked = Counter()
        let engine = TransferEngine { conflict in
            await asked.add(conflict.destinationName)
            return ConflictAnswer(.overwrite, applyToAll: true)
        }
        let done = await run(engine, TransferRequest(source: left, items: [FilePath("/src/tree")], destination: right,
                                                     destinationDirectory: FilePath("/dst"), operation: .copy))
        #expect(done?.state == .completed)
        #expect(await asked.names == ["a.txt"])   // the folder merged; "apply to all" answered b.txt
        #expect(await right.contents(of: FilePath("/dst/tree/sub/b.txt")) == Data("bb".utf8))
    }

    @Test func askCancelStopsTheTransfer() async {
        let (left, right) = await twoSources()
        await right.seed(FilePath("/dst/big.bin"), Data("old".utf8))
        let engine = TransferEngine { _ in ConflictAnswer(.cancel) }
        let done = await run(engine, TransferRequest(source: left, items: [FilePath("/src/big.bin")], destination: right,
                                                     destinationDirectory: FilePath("/dst"), operation: .copy))
        #expect(done?.state == .cancelled)
        #expect(await right.contents(of: FilePath("/dst/big.bin")) == Data("old".utf8))
    }

    @Test func cancelStopsMidFileAndRemovesThePartialCopy() async throws {
        let (left, right) = await twoSources()
        let source = FaultySource(left)
        await source.state.setPause(afterChunks: 3)
        let engine = TransferEngine(chunkSize: 100)
        let id = await engine.enqueue(TransferRequest(source: source, items: [FilePath("/src/big.bin")], destination: right,
                                                      destinationDirectory: FilePath("/dst"), operation: .copy))
        await source.state.waitUntilPaused()
        #expect(await right.contents(of: FilePath("/dst/big.bin"))?.count == 300)
        await engine.cancel(id)
        await source.state.open()
        let done = await engine.waitUntilFinished(id)
        #expect(done?.state == .cancelled)
        #expect(try await right.statIfExists(FilePath("/dst/big.bin")) == nil)
    }

    @Test func retryResumesAtTheOffsetReached() async throws {
        let (left, right) = await twoSources()
        let destination = FaultySource(right)
        await destination.state.setFailAfter(450)
        let source = FaultySource(left)
        let engine = TransferEngine(chunkSize: 100)
        let id = await engine.enqueue(TransferRequest(source: source, items: [FilePath("/src/big.bin")], destination: destination,
                                                      destinationDirectory: FilePath("/dst"), operation: .move))
        let failed = await engine.waitUntilFinished(id)
        #expect(failed?.state == .failed("link dropped"))
        #expect(await right.contents(of: FilePath("/dst/big.bin"))?.count == 400)
        #expect(await left.contents(of: FilePath("/src/big.bin")) != nil)   // a failed move keeps the source

        await engine.retry(id)
        let done = await engine.waitUntilFinished(id)
        #expect(done?.state == .completed)
        #expect(await source.state.readOffsets == [0, 400])
        #expect(await destination.state.writeOffsets == [0, 400])
        #expect(await right.contents(of: FilePath("/dst/big.bin")) == Self.bytes)
        #expect(try await left.statIfExists(FilePath("/src/big.bin")) == nil)
    }

    @Test func retryRestartsWhenTheSourceCannotSeek() async throws {
        let left = MemoryFileSource(id: "s3ish", displayName: "Bucket", capabilities: [.writable])
        await left.seed(FilePath("/big.bin"), Self.bytes)
        let right = MemoryFileSource()
        let destination = FaultySource(right)
        await destination.state.setFailAfter(250)
        let engine = TransferEngine(chunkSize: 100)
        let id = await engine.enqueue(TransferRequest(source: left, items: [FilePath("/big.bin")], destination: destination,
                                                      destinationDirectory: .root, operation: .copy))
        _ = await engine.waitUntilFinished(id)
        await engine.retry(id)
        let done = await engine.waitUntilFinished(id)
        #expect(done?.state == .completed)
        #expect(await destination.state.writeOffsets == [0, 0])
        #expect(await right.contents(of: FilePath("/big.bin")) == Self.bytes)
    }

    @Test func queueRunsInOrderWithinTheConcurrencyLimit() async throws {
        let (left, right) = await twoSources()
        let source = FaultySource(left)
        await source.state.setPause(afterChunks: 0)
        let engine = TransferEngine(chunkSize: 100, maxConcurrent: 1)
        let first = await engine.enqueue(TransferRequest(source: source, items: [FilePath("/src/big.bin")], destination: right,
                                                         destinationDirectory: FilePath("/dst"), operation: .copy))
        let second = await engine.enqueue(TransferRequest(source: left, items: [FilePath("/src/tree")], destination: right,
                                                          destinationDirectory: FilePath("/dst"), operation: .copy))
        await source.state.waitUntilPaused()
        #expect(await engine.snapshot(second)?.state == .queued)
        await engine.cancel(second)
        #expect(await engine.snapshot(second)?.state == .cancelled)
        await source.state.open()
        #expect(await engine.waitUntilFinished(first)?.state == .completed)
        #expect(try await right.statIfExists(FilePath("/dst/tree")) == nil)
        await engine.clearFinished()
        #expect(await engine.snapshots().isEmpty)
    }
}

actor Counter {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
