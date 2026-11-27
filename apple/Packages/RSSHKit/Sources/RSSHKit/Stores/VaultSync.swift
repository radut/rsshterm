import Foundation

/// Keeps several `VaultStore`s holding the same envelope. Pure logic over opaque bytes: it reads only the envelope's
/// unencrypted metadata (`updatedAt`, `deviceName`), never the vault.
///
/// `sync`: load every store at once; a store is *changed* when its revision differs from `SyncState`. If changed
/// stores disagree, that is a conflict: nothing is written and the caller lets the user pick (`resolve`). Otherwise
/// the newest changed envelope (or, with no change, the newest of all) wins and is written, with `ifMatch`, to every
/// store that holds something else. A failing store is reported and skipped; the others still sync.
///
/// Two rules keep one device's edit from being written over by another device's (a lost update):
/// - a store that missed a write the others took (`SyncState.behind`) and was changed meanwhile was written by a
///   device that never saw that write: a conflict with the stores holding it;
/// - the winner never replaces an envelope with the same or a higher vault revision and other contents (two devices
///   saved from the same base): a conflict too.
public enum VaultSync {
    public static func sync(_ stores: [any VaultStore], state: SyncState) async -> SyncReport {
        let snapshots = await loadAll(stores)
        let present = snapshots.compactMap(\.candidate)
        guard !present.isEmpty else {
            return SyncReport(winner: nil, results: zip(stores, snapshots).map { idle($0.id, $1, .empty) },
                              conflict: nil, state: state)
        }
        let changed = present.filter { state.revisions[$0.storeID] != $0.revision }
        if Set(changed.map(\.data)).count > 1 {
            return conflictReport(stores, snapshots, changed: changed, state: state)
        }
        // The stores that took the last write while others missed it, and still hold it.
        let holders = state.behind.isEmpty ? [] : present.filter { candidate in
            !state.behind.contains(candidate.storeID) && !changed.contains { $0.storeID == candidate.storeID }
        }
        if let edit = holders.first {
            let overwritten = changed.filter { state.behind.contains($0.storeID) && $0.data != edit.data }
            if !overwritten.isEmpty {
                return conflictReport(stores, snapshots, changed: inStoreOrder(holders + overwritten, stores), state: state)
            }
        }
        // max(by:) keeps the first of equals, so ties go to the earlier store.
        let winner = changed.isEmpty
            ? (holders.first ?? present.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }!)
            : changed.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }!
        let diverged = present.filter { isDiverged($0, from: winner) }
        if !diverged.isEmpty {
            return conflictReport(stores, snapshots, changed: inStoreOrder([winner] + diverged, stores), state: state)
        }
        var next = state
        var results: [StoreSyncResult] = []
        for (store, snapshot) in zip(stores, snapshots) {
            let result = await distribute(winner, to: store, snapshot)
            if let revision = result.revision { next.revisions[store.id] = revision }
            results.append(result)
        }
        next.behind = missed(results)
        return SyncReport(winner: winner, results: results, conflict: nil, state: next)
    }

    /// Whether `other` holds another device's save that `winner` was not built on: other contents with the same or a
    /// higher vault revision. Envelopes without a revision (before it existed) are never judged this way.
    static func isDiverged(_ other: SyncCandidate, from winner: SyncCandidate) -> Bool {
        guard other.data != winner.data, let theirs = vaultRevision(other.data),
              let ours = vaultRevision(winner.data) else { return false }
        return theirs >= ours
    }

    static func vaultRevision(_ data: Data) -> UInt64? {
        (try? JSONDecoder().decode(VaultEnvelope.self, from: data))?.revision
    }

    /// Stores that did not end up holding what was written: they are behind the others.
    private static func missed(_ results: [StoreSyncResult]) -> Set<String> {
        let wrote = results.contains { $0.status == .updated || $0.status == .upToDate }
        guard wrote else { return [] }
        return Set(results.filter { result in
            switch result.status {
            case .conflicted, .failed: true
            case .empty, .upToDate, .updated, .pending: false
            }
        }.map(\.storeID))
    }

    private static func inStoreOrder(_ candidates: [SyncCandidate], _ stores: [any VaultStore]) -> [SyncCandidate] {
        stores.compactMap { store in candidates.first { $0.storeID == store.id } }
    }

    /// Writes new envelope bytes (a local edit) to every store, each guarded by its revision in `state`.
    /// A store changed elsewhere since comes back `.conflicted`: sync first, then edit again.
    ///
    /// `takeOver`: stores only this device writes (its own file). One that refuses the guard is read again: if it holds
    /// an envelope no newer than `basedOn` (the revision this edit was built on), the guard was stale (SyncState from an
    /// older build, a file restored from the Keychain copy) and it is overwritten; if it holds a newer one, the report
    /// carries a conflict between that envelope and this edit (`unsavedEditID`) for the user to choose.
    public static func push(_ data: Data, to stores: [any VaultStore], state: SyncState,
                            takeOver: Set<String> = [], basedOn: UInt64? = nil) async -> SyncReport {
        var report = await write(data, to: stores, state: state, holder: nil)
        for (index, store) in stores.enumerated()
        where takeOver.contains(store.id) && report.results[index].status == .conflicted {
            let (result, conflict) = await reclaim(store, data: data, basedOn: basedOn, state: report.state)
            report.results[index] = result
            if let revision = result.revision { report.state.revisions[store.id] = revision }
            if let conflict { report.conflict = conflict }
        }
        // Nothing written anywhere: no store is ahead of another because of this edit.
        if report.results.contains(where: { $0.status == .updated }) { report.state.behind = missed(report.results) }
        return report
    }

    /// The candidate id of an edit not yet saved anywhere, in a conflict from `push`.
    public static let unsavedEditID = "unsaved-edit"

    /// Ends a conflict by keeping `candidate`: it is written to every other store, guarded by the revisions the
    /// conflicting sync saw, so a store changed yet again meanwhile is not overwritten.
    public static func resolve(_ conflict: SyncConflict, keeping candidate: SyncCandidate,
                               in stores: [any VaultStore]) async -> SyncReport {
        var report = await write(candidate.data, to: stores, state: SyncState(revisions: conflict.currentRevisions),
                                 holder: candidate.storeID)
        report.state.behind = missed(report.results)
        report.winner = candidate
        return report
    }

    // MARK: - steps

    enum Snapshot: Sendable {
        case empty
        case present(SyncCandidate)
        case failed(String)

        var candidate: SyncCandidate? {
            if case let .present(c) = self { c } else { nil }
        }
    }

    static func loadAll(_ stores: [any VaultStore]) async -> [Snapshot] {
        await withTaskGroup(of: (Int, Snapshot).self) { group in
            for (index, store) in stores.enumerated() {
                group.addTask { (index, await snapshot(of: store)) }
            }
            var byIndex: [Int: Snapshot] = [:]
            for await (index, snapshot) in group { byIndex[index] = snapshot }
            return stores.indices.map { byIndex[$0] ?? .failed("not loaded") }
        }
    }

    static func snapshot(of store: any VaultStore) async -> Snapshot {
        let stored: StoredVault
        do {
            guard let loaded = try await store.load() else { return .empty }
            stored = loaded
        } catch {
            return .failed(error.userMessage)
        }
        guard let envelope = try? JSONDecoder().decode(VaultEnvelope.self, from: stored.data) else {
            return .failed("What is stored there is not an rSshTerm vault; it was left untouched.")
        }
        return .present(SyncCandidate(storeID: store.id, revision: stored.revision, data: stored.data,
                                      updatedAt: envelope.updatedAt, deviceName: envelope.deviceName))
    }

    /// The result for a store that is not written to: failed stays failed, a present one keeps its revision.
    private static func idle(_ id: String, _ snapshot: Snapshot, _ status: StoreSyncStatus) -> StoreSyncResult {
        switch snapshot {
        case let .failed(message): StoreSyncResult(storeID: id, status: .failed(message))
        case let .present(c): StoreSyncResult(storeID: id, status: status, revision: c.revision)
        case .empty: StoreSyncResult(storeID: id, status: status)
        }
    }

    private static func conflictReport(_ stores: [any VaultStore], _ snapshots: [Snapshot], changed: [SyncCandidate],
                                       state: SyncState) -> SyncReport {
        let changedIDs = Set(changed.map(\.storeID))
        let results = zip(stores, snapshots).map { store, snapshot in
            idle(store.id, snapshot, changedIDs.contains(store.id) ? .conflicted : .pending)
        }
        let current = Dictionary(snapshots.compactMap(\.candidate).map { ($0.storeID, $0.revision) }) { a, _ in a }
        let conflict = SyncConflict(candidates: changed, currentRevisions: current)
        return SyncReport(winner: nil, results: results, conflict: conflict, state: state)
    }

    private static func distribute(_ winner: SyncCandidate, to store: any VaultStore,
                                   _ snapshot: Snapshot) async -> StoreSyncResult {
        switch snapshot {
        case .failed:
            return idle(store.id, snapshot, .upToDate)
        case let .present(c) where c.data == winner.data:
            return StoreSyncResult(storeID: store.id, status: .upToDate, revision: c.revision)
        case let .present(c):
            return await save(winner.data, to: store, ifMatch: c.revision)
        case .empty:
            return await save(winner.data, to: store, ifMatch: nil)
        }
    }

    private static func write(_ data: Data, to stores: [any VaultStore], state: SyncState,
                              holder: String?) async -> SyncReport {
        var next = state
        var results: [StoreSyncResult] = []
        for store in stores {
            let result = store.id == holder
                ? StoreSyncResult(storeID: store.id, status: .upToDate, revision: state.revisions[store.id])
                : await save(data, to: store, ifMatch: state.revisions[store.id])
            if let revision = result.revision { next.revisions[store.id] = revision }
            results.append(result)
        }
        return SyncReport(winner: nil, results: results, conflict: nil, state: next)
    }

    private static func reclaim(_ store: any VaultStore, data: Data, basedOn: UInt64?,
                                state: SyncState) async -> (StoreSyncResult, SyncConflict?) {
        let current: StoredVault?
        do {
            current = try await store.load()
        } catch {
            return (StoreSyncResult(storeID: store.id, status: .failed(error.userMessage)), nil)
        }
        guard let current else { return (await save(data, to: store, ifMatch: nil), nil) }
        let envelope = try? JSONDecoder().decode(VaultEnvelope.self, from: current.data)
        if (envelope?.revision ?? 0) <= (basedOn ?? 0) {
            return (await save(data, to: store, ifMatch: current.revision), nil)
        }
        let edit = try? JSONDecoder().decode(VaultEnvelope.self, from: data)
        var revisions = state.revisions
        revisions[store.id] = current.revision
        let conflict = SyncConflict(candidates: [
            SyncCandidate(storeID: store.id, revision: current.revision, data: current.data,
                          updatedAt: envelope?.updatedAt, deviceName: envelope?.deviceName),
            SyncCandidate(storeID: unsavedEditID, revision: "", data: data,
                          updatedAt: edit?.updatedAt, deviceName: edit?.deviceName),
        ], currentRevisions: revisions)
        return (StoreSyncResult(storeID: store.id, status: .conflicted, revision: nil), conflict)
    }

    private static func save(_ data: Data, to store: any VaultStore, ifMatch: String?) async -> StoreSyncResult {
        do {
            let revision = try await store.save(data, ifMatch: ifMatch)
            return StoreSyncResult(storeID: store.id, status: .updated, revision: revision)
        } catch VaultStoreError.conflict {
            return StoreSyncResult(storeID: store.id, status: .conflicted)
        } catch {
            return StoreSyncResult(storeID: store.id, status: .failed(error.userMessage))
        }
    }
}
