import Foundation
import Testing
@testable import RSSHKit

/// Envelope bytes with a vault revision, as a device would seal them.
func revisedEnvelope(_ marker: UInt8, revision: UInt64?, device: String = "phone") throws -> Data {
    let env = VaultEnvelope(wrappedKeys: [:], sealed: Data([marker]), updatedAt: Date(timeIntervalSince1970: 100),
                            deviceName: device, revision: revision)
    return try JSONEncoder().encode(env)
}

/// The device's own store must never stay stuck on a stale `ifMatch` (SyncState from an older build, a file restored
/// from the Keychain copy, state from another install): every later save would fail.
@Suite struct VaultPushTakeoverTests {
    func localFile() -> (LocalFileVaultStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-takeover-\(UUID().uuidString)")
        return (LocalFileVaultStore(fileURL: dir.appendingPathComponent("vault.json")), dir)
    }

    /// Path 3, before the fix: a stale revision in SyncState makes the push to the local file conflict.
    @Test func staleStateConflictsWithoutTakeover() async throws {
        let (file, dir) = localFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await file.save(try revisedEnvelope(1, revision: 4), ifMatch: nil)
        let report = await VaultSync.push(try revisedEnvelope(2, revision: 5), to: [file],
                                          state: SyncState(revisions: ["local": "stale"]))
        #expect(report.results.map(\.status) == [.conflicted])
    }

    @Test func ownStoreHoldingAnOlderRevisionIsOverwritten() async throws {
        let (file, dir) = localFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await file.save(try revisedEnvelope(1, revision: 4), ifMatch: nil)
        let edit = try revisedEnvelope(2, revision: 5)
        let report = await VaultSync.push(edit, to: [file], state: SyncState(revisions: ["local": "stale"]),
                                          takeOver: ["local"], basedOn: 4)
        #expect(report.results.map(\.status) == [.updated])
        #expect(try await file.load()?.data == edit)
        #expect(report.state.revisions["local"] == LocalFileVaultStore.revision(of: edit))
        #expect(report.conflict == nil)
    }

    @Test func ownStoreWithNoStateAndAFileIsOverwritten() async throws {
        let (file, dir) = localFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await file.save(try revisedEnvelope(1, revision: 2), ifMatch: nil)
        let edit = try revisedEnvelope(2, revision: 3)
        let report = await VaultSync.push(edit, to: [file], state: SyncState(), takeOver: ["local"], basedOn: 2)
        #expect(report.results.map(\.status) == [.updated])
        #expect(try await file.load()?.data == edit)
    }

    @Test func legacyEnvelopeWithoutRevisionIsOverwritten() async throws {
        let (file, dir) = localFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await file.save(try revisedEnvelope(1, revision: nil), ifMatch: nil)
        let edit = try revisedEnvelope(2, revision: 1)
        let report = await VaultSync.push(edit, to: [file], state: SyncState(), takeOver: ["local"], basedOn: nil)
        #expect(report.results.map(\.status) == [.updated])
    }

    @Test func ownStoreHoldingANewerRevisionIsAConflictToChoose() async throws {
        let (file, dir) = localFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let newer = try revisedEnvelope(9, revision: 7, device: "ipad")
        _ = try await file.save(newer, ifMatch: nil)
        let edit = try revisedEnvelope(2, revision: 5)
        let report = await VaultSync.push(edit, to: [file], state: SyncState(revisions: ["local": "stale"]),
                                          takeOver: ["local"], basedOn: 4)
        #expect(report.results.map(\.status) == [.conflicted])
        #expect(try await file.load()?.data == newer)
        let conflict = try #require(report.conflict)
        #expect(conflict.candidates.map(\.data) == [newer, edit])
        #expect(conflict.candidates.last?.storeID == VaultSync.unsavedEditID)
        #expect(conflict.currentRevisions["local"] == LocalFileVaultStore.revision(of: newer))
    }

    @Test func otherStoresKeepTheirGuard() async throws {
        let a = MemoryVaultStore(id: "drive")
        _ = try await a.save(try revisedEnvelope(1, revision: 1), ifMatch: nil)
        let report = await VaultSync.push(try revisedEnvelope(2, revision: 2), to: [a],
                                          state: SyncState(revisions: ["drive": "stale"]), takeOver: ["local"],
                                          basedOn: 1)
        #expect(report.results.map(\.status) == [.conflicted])
    }

    @Test func resolvingAnUnsavedEditWritesItEverywhere() async throws {
        let (file, dir) = localFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await file.save(try revisedEnvelope(9, revision: 7), ifMatch: nil)
        let edit = try revisedEnvelope(2, revision: 8)
        let report = await VaultSync.push(edit, to: [file], state: SyncState(), takeOver: ["local"], basedOn: 4)
        let conflict = try #require(report.conflict)
        let keep = try #require(conflict.candidates.last)
        let resolved = await VaultSync.resolve(conflict, keeping: keep, in: [file])
        #expect(resolved.results.map(\.status) == [.updated])
        #expect(try await file.load()?.data == edit)
    }

    /// The Keychain copy outlives the file: a save with the file gone still writes both.
    @Test func mirroredSaveWithTheFileGoneWritesFileAndCopy() async throws {
        let (file, dir) = localFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = MemoryVaultStore(id: "keychain")
        let store = MirroredVaultStore(primary: file, mirror: copy)
        let first = try revisedEnvelope(1, revision: 1)
        let rev = try await store.save(first, ifMatch: nil)
        try FileManager.default.removeItem(at: file.fileURL)
        let edit = try revisedEnvelope(2, revision: 2)
        let report = await VaultSync.push(edit, to: [store], state: SyncState(revisions: ["local": rev]),
                                          takeOver: ["local"], basedOn: 1)
        #expect(report.results.map(\.status) == [.updated])
        #expect(try await file.load()?.data == edit)
        #expect(try await copy.load()?.data == edit)
    }

    /// The file restored from a newer Keychain copy: a stale state must not block the next save.
    @Test func mirroredRestoreThenStaleStateStillSaves() async throws {
        let (file, dir) = localFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = MemoryVaultStore(id: "keychain")
        _ = try await file.save(try revisedEnvelope(1, revision: 1), ifMatch: nil)
        _ = try await copy.save(try revisedEnvelope(3, revision: 3), ifMatch: nil)
        let store = MirroredVaultStore(primary: file, mirror: copy)
        let edit = try revisedEnvelope(4, revision: 4)
        let report = await VaultSync.push(edit, to: [store],
                                          state: SyncState(revisions: ["local": LocalFileVaultStore.revision(of: try revisedEnvelope(1, revision: 1))]),
                                          takeOver: ["local"], basedOn: 3)
        #expect(report.results.map(\.status) == [.updated])
        #expect(try await file.load()?.data == edit)
        #expect(try await copy.load()?.data == edit)
    }
}
