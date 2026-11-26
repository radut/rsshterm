import Foundation

/// What the last sync saw, persisted by the app between syncs: store id -> revision that store had when it last
/// agreed with the others. A store whose revision differs now was changed since (by this or another device).
public struct SyncState: Codable, Hashable, Sendable {
    public var revisions: [String: String]

    public init(revisions: [String: String] = [:]) {
        self.revisions = revisions
    }
}

/// How one store ended a sync.
public enum StoreSyncStatus: Hashable, Sendable {
    /// Nothing stored there and nothing to write (every store is empty).
    case empty
    /// It already held the winning envelope.
    case upToDate
    /// The winning envelope was written to it.
    case updated
    /// It changed since the last sync, as did another store (or it changed while this write was on its way): left as it
    /// is until the user chooses, or until the next sync.
    case conflicted
    /// Not touched because a conflict between other stores is waiting to be resolved.
    case pending
    /// Loading, reading or writing failed; the message is fit to show.
    case failed(String)
}

public struct StoreSyncResult: Hashable, Sendable {
    public var storeID: String
    public var status: StoreSyncStatus
    /// The store's revision after the sync, when known.
    public var revision: String?

    public init(storeID: String, status: StoreSyncStatus, revision: String? = nil) {
        self.storeID = storeID
        self.status = status
        self.revision = revision
    }
}

/// One store's envelope, with the metadata a person needs to choose between versions.
public struct SyncCandidate: Hashable, Sendable {
    public var storeID: String
    public var revision: String
    public var data: Data
    public var updatedAt: Date?
    public var deviceName: String?
}

/// Two or more stores changed, to different contents, since the last sync. Nothing was written.
public struct SyncConflict: Hashable, Sendable {
    /// The changed stores, in store order.
    public var candidates: [SyncCandidate]
    /// Every readable store's revision at the time of the conflict, for `VaultSync.resolve`.
    public var currentRevisions: [String: String]
}

public struct SyncReport: Hashable, Sendable {
    /// The envelope every reachable store now holds; nil when all are empty, on a conflict, or for a push.
    public var winner: SyncCandidate?
    /// One result per store, in the order the stores were given.
    public var results: [StoreSyncResult]
    public var conflict: SyncConflict?
    /// The state to persist for the next sync.
    public var state: SyncState
}
