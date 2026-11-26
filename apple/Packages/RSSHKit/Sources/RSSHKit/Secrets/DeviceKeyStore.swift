import Foundation

/// This device's vault-wrapping key: a random 256-bit secret and the tag that names its envelope entry
/// (`DeviceKeyWrapper`).
public struct DeviceKeyMaterial: Codable, Hashable, Sendable {
    public let tag: String
    public let secret: Data

    public init(tag: String, secret: Data) {
        self.tag = tag
        self.secret = secret
    }

    public static func random() -> DeviceKeyMaterial {
        let m = DeviceKeyWrapper.newMaterial()
        return DeviceKeyMaterial(tag: m.tag, secret: m.secret)
    }

    public func wrapper() throws -> DeviceKeyWrapper { try DeviceKeyWrapper(tag: tag, secret: secret) }
}

public enum DeviceKeyStoreError: Error, Equatable, Sendable, LocalizedError {
    case alreadyExists
    case unreadable
    /// The user did not confirm (Touch ID, password) or the keychain refused.
    case denied(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists: "This device already has a vault key."
        case .unreadable: "This device's vault key could not be read."
        case .denied(let m): "This device's vault key could not be used. \(m)"
        }
    }
}

/// Where this device's key lives. iOS and macOS: the Keychain, this-device-only (on the Mac behind Touch ID, so
/// `requiresUserPresence`), implemented in the apps. Linux: `SecretStoreDeviceKeyStore` on `DesktopSecretStore`.
public protocol DeviceKeyStore: Sendable {
    /// True when reading the key asks the user (Touch ID, device password): the app opens the vault on demand.
    var requiresUserPresence: Bool { get }
    /// The key, nil when this device has none yet.
    func load() async throws -> DeviceKeyMaterial?
    /// Makes and stores a new key; throws `DeviceKeyStoreError.alreadyExists` when there is one.
    func create() async throws -> DeviceKeyMaterial
    /// Forgets the key (sign out, reset). The vault entries it wrapped stay until the next save drops them.
    func delete() async throws
}

extension DeviceKeyStore {
    public func loadOrCreate() async throws -> DeviceKeyMaterial {
        if let key = try await load() { return key }
        return try await create()
    }
}

/// `DeviceKeyStore` on a `SecretStore` (the Linux keyring or its file fallback), as JSON under one account.
public struct SecretStoreDeviceKeyStore: DeviceKeyStore {
    public static let account = "device-key"
    private let secrets: any SecretStore
    public let requiresUserPresence: Bool

    /// `requiresUserPresence`: a keyring that prompts to unlock. False for the file fallback and an unlocked keyring.
    public init(secrets: any SecretStore, requiresUserPresence: Bool = false) {
        self.secrets = secrets
        self.requiresUserPresence = requiresUserPresence
    }

    public func load() async throws -> DeviceKeyMaterial? {
        guard let data = try await secrets.read(account: Self.account) else { return nil }
        guard let key = try? JSONDecoder().decode(DeviceKeyMaterial.self, from: data), key.secret.count == 32,
              (try? key.wrapper()) != nil else { throw DeviceKeyStoreError.unreadable }
        return key
    }

    public func create() async throws -> DeviceKeyMaterial {
        guard try await load() == nil else { throw DeviceKeyStoreError.alreadyExists }
        let key = DeviceKeyMaterial.random()
        try await secrets.write(try JSONEncoder().encode(key), account: Self.account)
        return key
    }

    public func delete() async throws {
        try await secrets.delete(account: Self.account)
    }
}

/// An in-memory `DeviceKeyStore`: the test double for the apps' Keychain stores.
public actor MemoryDeviceKeyStore: DeviceKeyStore {
    public nonisolated let requiresUserPresence: Bool
    private var key: DeviceKeyMaterial?

    public init(requiresUserPresence: Bool = false, key: DeviceKeyMaterial? = nil) {
        self.requiresUserPresence = requiresUserPresence
        self.key = key
    }

    public func load() async throws -> DeviceKeyMaterial? { key }

    public func create() async throws -> DeviceKeyMaterial {
        guard key == nil else { throw DeviceKeyStoreError.alreadyExists }
        let new = DeviceKeyMaterial.random()
        key = new
        return new
    }

    public func delete() async throws { key = nil }
}
