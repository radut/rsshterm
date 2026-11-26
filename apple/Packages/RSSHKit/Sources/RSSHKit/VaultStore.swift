import Foundation

/// One place the encrypted vault is kept: Google Drive appDataFolder, an S3 bucket, a local file. The user can enable
/// several; each stores the same opaque `VaultEnvelope` bytes and never sees plaintext.
public protocol VaultStore: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// nil when nothing has been stored yet.
    func load() async throws -> StoredVault?
    /// `ifMatch`: the revision last loaded, so a concurrent writer is detected instead of overwritten.
    func save(_ data: Data, ifMatch revision: String?) async throws -> String
}

public struct StoredVault: Hashable, Sendable {
    public var data: Data
    /// Opaque version tag from the backend (Drive file version / S3 ETag / file mtime).
    public var revision: String

    public init(data: Data, revision: String) {
        self.data = data
        self.revision = revision
    }
}

public enum VaultStoreError: Error, Equatable {
    case conflict(currentRevision: String)
}

/// In-memory store, for tests and previews.
public actor MemoryVaultStore: VaultStore {
    public nonisolated let id: String
    public nonisolated let displayName: String
    private var current: StoredVault?
    private var counter = 0

    public init(id: String = "memory", displayName: String = "Memory") {
        self.id = id
        self.displayName = displayName
    }

    public func load() async throws -> StoredVault? { current }

    public func save(_ data: Data, ifMatch revision: String?) async throws -> String {
        if let current, current.revision != revision {
            throw VaultStoreError.conflict(currentRevision: current.revision)
        }
        counter += 1
        let rev = String(counter)
        current = StoredVault(data: data, revision: rev)
        return rev
    }
}
