import Foundation
import Testing
@testable import RSSHKit

/// Envelope bytes at a vault revision, as a device would write them.
func envelopeData(_ marker: UInt8, revision: UInt64, at seconds: TimeInterval, device: String) throws -> Data {
    let env = VaultEnvelope(wrappedKeys: [:], sealed: Data([marker]), updatedAt: Date(timeIntervalSince1970: seconds),
                            deviceName: device, revision: revision)
    return try JSONEncoder().encode(env)
}

/// The owner's report: the iPhone's ledger said 84 while iCloud held 83. The phone saved 83 and 84 to its own file
/// while its iCloud writes were refused (the Mac had written 83 there meanwhile); the next sync took the changed iCloud
/// copy as the winner and wrote it over the phone's file, so the phone's edits were lost and 83 was refused.
@Suite struct VaultSyncDivergenceTests {
    let local = MemoryVaultStore(id: "local"), cloud = MemoryVaultStore(id: "icloud")

    /// Both stores at revision 82, as the last sync left them.
    func inSync() async throws -> SyncState {
        let base = try envelopeData(82, revision: 82, at: 100, device: "iPhone")
        let rl = try await local.save(base, ifMatch: nil), rc = try await cloud.save(base, ifMatch: nil)
        return SyncState(revisions: ["local": rl, "icloud": rc])
    }

    /// The Mac saves its own 83 (based on 82) straight to iCloud.
    func macSaves(_ revision: UInt64 = 83, at seconds: TimeInterval = 200) async throws -> Data {
        let data = try envelopeData(UInt8(revision) + 100, revision: revision, at: seconds, device: "Mac")
        let current = try #require(try await cloud.load())
        _ = try await cloud.save(data, ifMatch: current.revision)
        return data
    }

    @Test func phoneEditsThatMissedICloudAreNotOverwrittenByTheMacsCopy() async throws {
        var state = try await inSync()
        let mac = try await macSaves()
        let e83 = try envelopeData(83, revision: 83, at: 300, device: "iPhone")
        var report = await VaultSync.push(e83, to: [local, cloud], state: state, takeOver: ["local"], basedOn: 82)
        #expect(report.results.map(\.status) == [.updated, .conflicted])
        state = report.state
        let e84 = try envelopeData(84, revision: 84, at: 400, device: "iPhone")
        report = await VaultSync.push(e84, to: [local, cloud], state: state, takeOver: ["local"], basedOn: 83)
        state = report.state

        let sync = await VaultSync.sync([local, cloud], state: state)
        #expect(try await local.load()?.data == e84)
        #expect(try await cloud.load()?.data == mac)
        let conflict = try #require(sync.conflict)
        #expect(Set(conflict.candidates.map(\.data)) == [e84, mac])
        #expect(sync.winner == nil)
    }

    /// A phone whose SyncState came from the build before the fix (no record of the missed iCloud write): the local
    /// copy's higher revision alone keeps it from being overwritten.
    @Test func aHigherRevisionIsNeverOverwrittenByALowerChangedCopy() async throws {
        let state = try await inSync()
        let e84 = try envelopeData(84, revision: 84, at: 400, device: "iPhone")
        let rl = try #require(try await local.load()?.revision)
        let rl2 = try await local.save(e84, ifMatch: rl)
        let mac = try await macSaves()
        var old = state
        old.revisions["local"] = rl2

        let sync = await VaultSync.sync([local, cloud], state: old)
        #expect(try await local.load()?.data == e84)
        let conflict = try #require(sync.conflict)
        #expect(Set(conflict.candidates.map(\.data)) == [e84, mac])
    }

    /// The same revision number from two devices with different contents is a divergence too.
    @Test func theSameRevisionWithOtherContentsIsAConflict() async throws {
        let state = try await inSync()
        let e83 = try envelopeData(83, revision: 83, at: 300, device: "iPhone")
        let rl = try #require(try await local.load()?.revision)
        var old = state
        old.revisions["local"] = try await local.save(e83, ifMatch: rl)
        _ = try await macSaves()
        let sync = await VaultSync.sync([local, cloud], state: old)
        #expect(sync.conflict != nil)
        #expect(try await local.load()?.data == e83)
    }

    /// The Mac saved twice (84 > the phone's 83): only the record of the missed write tells this is no plain update.
    @Test func aMissedWriteIsAConflictEvenWhenTheOtherCopyIsNewer() async throws {
        let state = try await inSync()
        _ = try await macSaves(83, at: 200)
        let e83 = try envelopeData(83, revision: 83, at: 300, device: "iPhone")
        let push = await VaultSync.push(e83, to: [local, cloud], state: state, takeOver: ["local"], basedOn: 82)
        #expect(push.state.behind == ["icloud"])
        _ = try await macSaves(84, at: 500)
        let sync = await VaultSync.sync([local, cloud], state: push.state)
        #expect(sync.conflict != nil)
        #expect(try await local.load()?.data == e83)
    }

    /// iCloud offline during the edit, nobody else wrote: the next sync sends the edit up, and the record clears.
    @Test func aMissedWriteToAnUnchangedStoreIsSentNextTime() async throws {
        let state = try await inSync()
        let e83 = try envelopeData(83, revision: 83, at: 300, device: "iPhone")
        let down = FailingStore(id: "icloud")
        let push = await VaultSync.push(e83, to: [local, down], state: state, takeOver: ["local"], basedOn: 82)
        #expect(push.state.behind == ["icloud"])
        let sync = await VaultSync.sync([local, cloud], state: push.state)
        #expect(sync.conflict == nil)
        #expect(sync.winner?.data == e83)
        #expect(try await cloud.load()?.data == e83)
        #expect(sync.state.behind.isEmpty)
    }

    /// The normal multi-device case still just works: the Mac saved 83 on top of the phone's 82.
    @Test func aPlainUpdateFromAnotherDeviceStillWins() async throws {
        let state = try await inSync()
        let mac = try await macSaves()
        let sync = await VaultSync.sync([local, cloud], state: state)
        #expect(sync.conflict == nil)
        #expect(try await local.load()?.data == mac)
    }

    /// Resolving the conflict clears the record, and the following sync is quiet.
    @Test func resolvingClearsTheMissedWrite() async throws {
        let state = try await inSync()
        _ = try await macSaves()
        let e83 = try envelopeData(83, revision: 83, at: 300, device: "iPhone")
        let push = await VaultSync.push(e83, to: [local, cloud], state: state, takeOver: ["local"], basedOn: 82)
        let sync = await VaultSync.sync([local, cloud], state: push.state)
        let conflict = try #require(sync.conflict)
        let keep = try #require(conflict.candidates.first { $0.data == e83 })
        let resolved = await VaultSync.resolve(conflict, keeping: keep, in: [local, cloud])
        #expect(resolved.state.behind.isEmpty)
        #expect(try await cloud.load()?.data == e83)
        let again = await VaultSync.sync([local, cloud], state: resolved.state)
        #expect(again.conflict == nil)
        #expect(again.results.map(\.status) == [.upToDate, .upToDate])
    }

    /// A SyncState saved before `behind` existed still decodes.
    @Test func oldSyncStateDecodes() throws {
        let state = try JSONDecoder().decode(SyncState.self, from: Data(#"{"revisions":{"local":"a"}}"#.utf8))
        #expect(state == SyncState(revisions: ["local": "a"]))
        let again = try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(SyncState(revisions: [:], behind: ["x"])))
        #expect(again.behind == ["x"])
    }
}
