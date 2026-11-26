import Foundation
import Testing
@testable import RSSHKit

/// A store whose load and save always fail, like Drive while offline.
struct FailingStore: VaultStore {
    struct Offline: Error, LocalizedError {
        var errorDescription: String? { "offline" }
    }
    let id: String
    var displayName: String { id }
    func load() async throws -> StoredVault? { throw Offline() }
    func save(_ data: Data, ifMatch revision: String?) async throws -> String { throw Offline() }
}

/// Envelope bytes with a given timestamp, as a device would write them.
func envelopeData(_ marker: UInt8, at seconds: TimeInterval?, device: String = "phone") throws -> Data {
    let env = VaultEnvelope(wrappedKeys: [:], sealed: Data([marker]),
                            updatedAt: seconds.map { Date(timeIntervalSince1970: $0) }, deviceName: device)
    return try JSONEncoder().encode(env)
}

@Suite struct VaultSyncTests {
    @Test func allStoresEmpty() async {
        let a = MemoryVaultStore(id: "a"), b = MemoryVaultStore(id: "b")
        let report = await VaultSync.sync([a, b], state: SyncState())
        #expect(report.winner == nil)
        #expect(report.conflict == nil)
        #expect(report.results.map(\.status) == [.empty, .empty])
        #expect(report.state == SyncState())
    }

    @Test func oneStoreIsTheWinner() async throws {
        let a = MemoryVaultStore(id: "a")
        let rev = try await a.save(try envelopeData(1, at: 100), ifMatch: nil)
        let report = await VaultSync.sync([a], state: SyncState())
        #expect(report.winner?.storeID == "a")
        #expect(report.winner?.updatedAt == Date(timeIntervalSince1970: 100))
        #expect(report.winner?.deviceName == "phone")
        #expect(report.results == [StoreSyncResult(storeID: "a", status: .upToDate, revision: rev)])
        #expect(report.state.revisions == ["a": rev])
    }

    @Test func twoStoresInSyncWriteNothing() async throws {
        let a = MemoryVaultStore(id: "a"), b = MemoryVaultStore(id: "b")
        let data = try envelopeData(1, at: 100)
        let ra = try await a.save(data, ifMatch: nil), rb = try await b.save(data, ifMatch: nil)
        let report = await VaultSync.sync([a, b], state: SyncState(revisions: ["a": ra, "b": rb]))
        #expect(report.results.map(\.status) == [.upToDate, .upToDate])
        #expect(try await b.load()?.revision == rb)
        #expect(report.conflict == nil)
    }

    @Test func staleStoreGetsTheNewestEnvelope() async throws {
        let a = MemoryVaultStore(id: "a"), b = MemoryVaultStore(id: "b")
        let old = try envelopeData(1, at: 100)
        let ra = try await a.save(old, ifMatch: nil), rb = try await b.save(old, ifMatch: nil)
        let new = try envelopeData(2, at: 200)
        let ra2 = try await a.save(new, ifMatch: ra)

        let report = await VaultSync.sync([a, b], state: SyncState(revisions: ["a": ra, "b": rb]))
        #expect(report.winner?.storeID == "a")
        #expect(report.winner?.data == new)
        #expect(try await b.load()?.data == new)
        let rb2 = try #require(try await b.load()?.revision)
        #expect(report.results == [StoreSyncResult(storeID: "a", status: .upToDate, revision: ra2),
                                   StoreSyncResult(storeID: "b", status: .updated, revision: rb2)])
        #expect(report.state.revisions == ["a": ra2, "b": rb2])
    }

    @Test func emptyStoreIsFilled() async throws {
        let a = MemoryVaultStore(id: "a"), b = MemoryVaultStore(id: "b")
        let data = try envelopeData(1, at: 100)
        _ = try await a.save(data, ifMatch: nil)
        let report = await VaultSync.sync([a, b], state: SyncState())
        #expect(try await b.load()?.data == data)
        #expect(report.results.map(\.status) == [.upToDate, .updated])
    }

    @Test func changedStoreWinsOverUnchangedOneEvenWhenOlderByClock() async throws {
        // a is known and unchanged; b changed since: b wins even though it is not newer by clock.
        let a = MemoryVaultStore(id: "a"), b = MemoryVaultStore(id: "b")
        let ra = try await a.save(try envelopeData(1, at: 500), ifMatch: nil)
        let bData = try envelopeData(2, at: 100)
        _ = try await b.save(bData, ifMatch: nil)
        let report = await VaultSync.sync([a, b], state: SyncState(revisions: ["a": ra, "b": "old"]))
        #expect(report.winner?.storeID == "b")
        #expect(try await a.load()?.data == bData)
    }

    @Test func twoStoresChangedIsAConflictAndNothingIsWritten() async throws {
        let a = MemoryVaultStore(id: "a"), b = MemoryVaultStore(id: "b"), c = MemoryVaultStore(id: "c")
        let base = try envelopeData(0, at: 50)
        let ra = try await a.save(base, ifMatch: nil), rb = try await b.save(base, ifMatch: nil)
        let rc = try await c.save(base, ifMatch: nil)
        let ra2 = try await a.save(try envelopeData(1, at: 100, device: "phone"), ifMatch: ra)
        let rb2 = try await b.save(try envelopeData(2, at: 200, device: "ipad"), ifMatch: rb)

        let report = await VaultSync.sync([a, b, c], state: SyncState(revisions: ["a": ra, "b": rb, "c": rc]))
        let conflict = try #require(report.conflict)
        #expect(report.winner == nil)
        #expect(conflict.candidates.map(\.storeID) == ["a", "b"])
        #expect(conflict.candidates.map(\.deviceName) == ["phone", "ipad"])
        #expect(conflict.currentRevisions == ["a": ra2, "b": rb2, "c": rc])
        #expect(report.results.map(\.status) == [.conflicted, .conflicted, .pending])
        #expect(try await c.load()?.data == base)
        #expect(report.state.revisions == ["a": ra, "b": rb, "c": rc])
    }

    @Test func resolvingAConflictWritesTheChosenEnvelopeEverywhere() async throws {
        let a = MemoryVaultStore(id: "a"), b = MemoryVaultStore(id: "b")
        _ = try await a.save(try envelopeData(1, at: 100), ifMatch: nil)
        _ = try await b.save(try envelopeData(2, at: 200), ifMatch: nil)
        let report = await VaultSync.sync([a, b], state: SyncState())
        let conflict = try #require(report.conflict)
        let keep = try #require(conflict.candidates.first { $0.storeID == "a" })

        let resolved = await VaultSync.resolve(conflict, keeping: keep, in: [a, b])
        #expect(try await b.load()?.data == keep.data)
        #expect(resolved.results.map(\.status) == [.upToDate, .updated])
        #expect(resolved.winner?.storeID == "a")
        let again = await VaultSync.sync([a, b], state: resolved.state)
        #expect(again.results.map(\.status) == [.upToDate, .upToDate])
    }

    @Test func failingStoreIsReportedAndOthersStillSync() async throws {
        let a = MemoryVaultStore(id: "a"), down = FailingStore(id: "down"), b = MemoryVaultStore(id: "b")
        let data = try envelopeData(1, at: 100)
        _ = try await a.save(data, ifMatch: nil)
        let report = await VaultSync.sync([a, down, b], state: SyncState(revisions: ["down": "7"]))
        #expect(report.results.map(\.status) == [.upToDate, .failed("offline"), .updated])
        #expect(try await b.load()?.data == data)
        #expect(report.state.revisions["down"] == "7")
    }

    @Test func undecodableContentIsAFailureAndIsNotOverwritten() async throws {
        let a = MemoryVaultStore(id: "a"), junk = MemoryVaultStore(id: "junk")
        _ = try await a.save(try envelopeData(1, at: 100), ifMatch: nil)
        _ = try await junk.save(Data("not json".utf8), ifMatch: nil)
        let report = await VaultSync.sync([a, junk], state: SyncState())
        guard case .failed = report.results[1].status else {
            Issue.record("expected failure, got \(report.results[1].status)")
            return
        }
        #expect(try await junk.load()?.data == Data("not json".utf8))
    }

    @Test func pushWritesNewLocalEditsGuardedByRevision() async throws {
        let a = MemoryVaultStore(id: "a"), b = MemoryVaultStore(id: "b")
        let base = try envelopeData(0, at: 50)
        let ra = try await a.save(base, ifMatch: nil), rb = try await b.save(base, ifMatch: nil)
        _ = try await b.save(try envelopeData(9, at: 60), ifMatch: rb) // someone else wrote b

        let edit = try envelopeData(1, at: 100)
        let report = await VaultSync.push(edit, to: [a, b], state: SyncState(revisions: ["a": ra, "b": rb]))
        #expect(report.results[0].status == .updated)
        #expect(report.results[1].status == .conflicted)
        #expect(try await a.load()?.data == edit)
        #expect(report.state.revisions["b"] == rb)
    }
}
