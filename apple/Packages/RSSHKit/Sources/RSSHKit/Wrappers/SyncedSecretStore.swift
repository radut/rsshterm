import Foundation

/// Why the synced store could not be used. Messages are for people.
public enum SyncedSecretStoreError: Error, Equatable, Sendable, LocalizedError {
    /// iCloud Keychain refused the item (signed out of iCloud, Keychain off, a restricted device).
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let m): m
        }
    }
}

/// Where the iCloud Keychain key is kept: in the app, a Keychain item with `kSecAttrSynchronizable = true` (so iCloud
/// Keychain copies it to the user's other Apple devices); in tests, memory. One item, never replaced once stored.
public protocol SyncedSecretStore: Sendable {
    /// The stored bytes, nil when there are none (yet: iCloud Keychain may still be bringing them over).
    func read() throws -> Data?
    /// Stores `data` when nothing is stored yet; false when an item was already there (it is left as it is).
    func addIfAbsent(_ data: Data) throws -> Bool
}

/// An in-memory `SyncedSecretStore`. Two "devices" sharing one instance see the same item, as two iPhones on the same
/// Apple ID do once iCloud Keychain has synced.
public final class MemorySyncedSecretStore: SyncedSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var item: Data?
    private let failure: SyncedSecretStoreError?

    public init(failure: SyncedSecretStoreError? = nil) {
        self.failure = failure
    }

    public func read() throws -> Data? {
        if let failure { throw failure }
        return lock.withLock { item }
    }

    public func addIfAbsent(_ data: Data) throws -> Bool {
        if let failure { throw failure }
        return lock.withLock {
            guard item == nil else { return false }
            item = data
            return true
        }
    }
}
