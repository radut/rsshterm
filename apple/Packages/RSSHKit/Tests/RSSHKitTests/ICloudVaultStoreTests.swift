import Foundation
import Testing
@testable import RSSHKit

/// A CloudKit private database stand-in: one record, a change tag that moves with every save, and the
/// `.ifServerRecordUnchanged` rule (a save based on an old tag, or a create over an existing record, is refused).
actor FakeCloudDatabase: CloudRecordDatabase {
    private(set) var record: CloudRecord?
    private(set) var saves = 0
    private var counter = 0
    var failure: CloudRecordError?

    init(record: CloudRecord? = nil) { self.record = record }

    func set(failure: CloudRecordError?) { self.failure = failure }

    /// Another device saves meanwhile.
    func changeElsewhere(_ data: Data) {
        counter += 1
        record = CloudRecord(data: data, changeTag: "elsewhere-\(counter)")
    }

    func fetch() async throws -> CloudRecord? {
        if let failure { throw failure }
        return record
    }

    func save(_ data: Data, ifChangeTag tag: String?) async throws -> String {
        if let failure { throw failure }
        saves += 1
        guard record?.changeTag == tag else { throw CloudRecordError.changed(currentTag: record?.changeTag) }
        counter += 1
        let next = "tag-\(counter)"
        record = CloudRecord(data: data, changeTag: next)
        return next
    }
}

@Suite struct ICloudVaultStoreTests {
    @Test func identity() {
        let store = ICloudVaultStore(database: FakeCloudDatabase())
        #expect(store.id == "icloud")
        #expect(store.displayName == "iCloud")
    }

    @Test func missingRecordLoadsAsNothing() async throws {
        #expect(try await ICloudVaultStore(database: FakeCloudDatabase()).load() == nil)
    }

    @Test func createsTheRecordThenLoadsIt() async throws {
        let db = FakeCloudDatabase()
        let store = ICloudVaultStore(database: db)
        let tag = try await store.save(Data("v1".utf8), ifMatch: nil)
        #expect(try await store.load() == StoredVault(data: Data("v1".utf8), revision: tag))
    }

    @Test func createOverAnExistingRecordIsAConflict() async throws {
        let db = FakeCloudDatabase(record: CloudRecord(data: Data("theirs".utf8), changeTag: "t9"))
        await #expect(throws: VaultStoreError.conflict(currentRevision: "t9")) {
            try await ICloudVaultStore(database: db).save(Data("mine".utf8), ifMatch: nil)
        }
        #expect(await db.record?.data == Data("theirs".utf8))
    }

    @Test func updatesWhenTheTagStillMatches() async throws {
        let db = FakeCloudDatabase()
        let store = ICloudVaultStore(database: db)
        let first = try await store.save(Data("v1".utf8), ifMatch: nil)
        let second = try await store.save(Data("v2".utf8), ifMatch: first)
        #expect(second != first)
        #expect(try await store.load() == StoredVault(data: Data("v2".utf8), revision: second))
    }

    @Test func aChangeElsewhereComesBackAsAConflict() async throws {
        let db = FakeCloudDatabase()
        let store = ICloudVaultStore(database: db)
        let first = try await store.save(Data("v1".utf8), ifMatch: nil)
        await db.changeElsewhere(Data("other".utf8))
        await #expect(throws: VaultStoreError.conflict(currentRevision: "elsewhere-2")) {
            try await store.save(Data("v2".utf8), ifMatch: first)
        }
        #expect(await db.record?.data == Data("other".utf8))
    }

    @Test func syncSettlesAConflictWithAnotherDevice() async throws {
        let db = FakeCloudDatabase()
        let store = ICloudVaultStore(database: db)
        let report = await VaultSync.push(Data("mine".utf8), to: [store], state: SyncState())
        #expect(report.conflict == nil)
        #expect(try await store.load()?.data == Data("mine".utf8))
    }

    @Test(arguments: [
        (CloudRecordError.notSignedIn, "Sign in to iCloud"),
        (CloudRecordError.unavailable("offline"), "offline"),
    ])
    func accountProblemsAreExplained(_ error: CloudRecordError, _ text: String) async {
        let db = FakeCloudDatabase()
        await db.set(failure: error)
        do {
            _ = try await ICloudVaultStore(database: db).load()
            Issue.record("expected an error")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription?.contains(text) == true)
        }
    }
}
