import Foundation

/// One record as the iCloud store sees it: the envelope bytes and the server's change tag (its revision).
public struct CloudRecord: Hashable, Sendable {
    public var data: Data
    public var changeTag: String

    public init(data: Data, changeTag: String) {
        self.data = data
        self.changeTag = changeTag
    }
}

/// What the record database can answer besides success. Messages are for people.
public enum CloudRecordError: Error, Equatable, Sendable, LocalizedError {
    /// The save was based on `ifChangeTag`, but the record changed (or appeared) on the server meanwhile.
    case changed(currentTag: String?)
    /// No iCloud account on this device, or iCloud is restricted for the app.
    case notSignedIn
    /// iCloud did not answer or refused for now (offline, throttled, quota, a server error).
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .changed: "The vault was changed in iCloud by another device. Sync again."
        case .notSignedIn: "Sign in to iCloud in the Settings app to keep the vault in iCloud."
        case .unavailable(let m): "iCloud is not available right now: \(m)"
        }
    }
}

/// The one vault record in the user's private iCloud database (CloudKit in the app, a fake in tests).
public protocol CloudRecordDatabase: Sendable {
    /// The record, nil when there is none yet.
    func fetch() async throws -> CloudRecord?
    /// Creates the record (`ifChangeTag` nil: only when none exists) or updates it when the server's change tag is
    /// still `ifChangeTag`; returns the new tag. Throws `CloudRecordError.changed` otherwise.
    func save(_ data: Data, ifChangeTag: String?) async throws -> String
}

/// The vault envelope as one record in the user's private iCloud database. Only the user's Apple ID can read it,
/// and it only ever holds the sealed vault. The revision is the record's change tag; a save based on an older tag
/// is a conflict, never an overwrite.
public struct ICloudVaultStore: VaultStore {
    public static let storeID = "icloud"
    public let id = ICloudVaultStore.storeID
    public let displayName = "iCloud"
    private let database: any CloudRecordDatabase

    public init(database: any CloudRecordDatabase) {
        self.database = database
    }

    public func load() async throws -> StoredVault? {
        guard let record = try await database.fetch() else { return nil }
        return StoredVault(data: record.data, revision: record.changeTag)
    }

    public func save(_ data: Data, ifMatch revision: String?) async throws -> String {
        do {
            return try await database.save(data, ifChangeTag: revision)
        } catch CloudRecordError.changed(let current) {
            throw VaultStoreError.conflict(currentRevision: current ?? "")
        }
    }
}
