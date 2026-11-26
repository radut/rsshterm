import Foundation

/// Why a secret could not be read or kept. Messages are for people and never carry the secret.
public enum SecretStoreError: Error, Equatable, Sendable, LocalizedError {
    /// The account name is not `[a-z0-9._-]+` (it becomes a file name and a keyring attribute).
    case badAccount(String)
    /// The keyring or file could not be reached; the message says why.
    case unavailable(String)
    /// The stored item is not what this app wrote.
    case unreadable(String)
    /// The file holding a secret can be read by other users: refused until it is fixed (chmod 600).
    case insecurePermissions(String)

    public var errorDescription: String? {
        switch self {
        case .badAccount(let a): "\"\(a)\" is not a valid secret name."
        case .unavailable(let m): "The keyring could not be used. \(m)"
        case .unreadable(let a): "The stored secret \"\(a)\" could not be read."
        case .insecurePermissions(let path): "\(path) can be read by other users. Run: chmod 600 \(path)"
        }
    }
}

/// Small named secrets kept by the platform: this device's vault key, the Google sign-in tokens. On Linux the Secret
/// Service (GNOME Keyring, KWallet) through `secret-tool`, else an owner-only file (`DesktopSecretStore`); on the
/// Apple platforms the apps keep their own Keychain code. Async because a keyring may ask the user to unlock it.
public protocol SecretStore: Sendable {
    /// nil when nothing is stored under `account`.
    func read(account: String) async throws -> Data?
    /// Stores `data` under `account`, replacing what was there.
    func write(_ data: Data, account: String) async throws
    /// Removes `account`; removing nothing is not an error.
    func delete(account: String) async throws
}

enum SecretAccount {
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")

    static func validate(_ account: String) throws {
        guard !account.isEmpty, account.count <= 64, account.allSatisfy(allowed.contains),
              account != ".", account != ".." else { throw SecretStoreError.badAccount(account) }
    }
}

/// An in-memory `SecretStore`, for tests and previews.
public actor MemorySecretStore: SecretStore {
    private var items: [String: Data] = [:]

    public init() {}

    public func read(account: String) async throws -> Data? {
        try SecretAccount.validate(account)
        return items[account]
    }

    public func write(_ data: Data, account: String) async throws {
        try SecretAccount.validate(account)
        items[account] = data
    }

    public func delete(account: String) async throws {
        try SecretAccount.validate(account)
        items[account] = nil
    }
}
