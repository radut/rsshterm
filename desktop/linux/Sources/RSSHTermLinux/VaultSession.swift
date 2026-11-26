import Foundation
import RSSHKit

public enum VaultLoadResult: Equatable, Sendable {
    /// Nothing stored yet: offer to create a vault (or sign in to Google Drive to find one).
    case noVault
    /// None of this device's keys opens it: ask for the master password (a new device).
    case needsMasterPassword
    case opened(Vault)
}

public enum VaultSessionError: Error, Equatable, Sendable, LocalizedError {
    case passwordTooShort
    case wrongPassword
    /// No key of this device opens the vault and it has no master password entry.
    case cannotOpen
    case notOpen
    case badPlainVault(String)

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort: "The master password needs at least \(MasterPasswordKeyWrapper.minimumLength) characters."
        case .wrongPassword: "That master password does not open this vault."
        case .cannotOpen: "No key of this device opens the vault, and it has no master password."
        case .notOpen: "The vault is locked."
        case .badPlainVault(let m): "Not a vault file: \(m)"
        }
    }
}

/// The vault as the Linux app holds it: one store (the local file, or Google Drive), this device's key from the
/// keyring, and the master password for a device that has never opened the vault. After a master-password unlock
/// the vault is saved again with this device's key added, so the next launch opens it with no password.
public actor VaultSession {
    private let store: any VaultStore
    private let deviceKeys: any DeviceKeyStore
    private let deviceName: String?
    private let kdf: MasterPasswordKDF
    private let now: @Sendable () -> Date

    private var revision: String?
    private var envelope: VaultEnvelope?
    private var opened: OpenedVault?

    public init(store: any VaultStore, deviceKeys: any DeviceKeyStore, deviceName: String?,
                kdf: MasterPasswordKDF = .default, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.deviceKeys = deviceKeys
        self.deviceName = deviceName
        self.kdf = kdf
        self.now = now
    }

    public var storeName: String { store.displayName }
    public var vault: Vault? { opened?.vault }
    public var hasMasterPassword: Bool { envelope?.masterPasswordID != nil }

    public func load() async throws -> VaultLoadResult {
        guard let stored = try await store.load() else {
            revision = nil
            envelope = nil
            opened = nil
            return .noVault
        }
        let env = try JSONDecoder().decode(VaultEnvelope.self, from: stored.data)
        revision = stored.revision
        envelope = env
        let wrappers: [any KeyWrapper] = try await deviceKeys.load().map { [try $0.wrapper()] } ?? []
        do {
            switch try await VaultOpener.open(env, wrappers: wrappers) {
            case .opened(let o):
                opened = o
                return .opened(o.vault)
            case .needsMasterPassword:
                opened = nil
                return .needsMasterPassword
            }
        } catch VaultError.noUsableWrapper {
            throw VaultSessionError.cannotOpen
        }
    }

    /// Opens with the master password and saves the vault with this device's key added.
    public func unlock(masterPassword: String) async throws -> Vault {
        guard let env = envelope else { throw VaultSessionError.notOpen }
        let device = try await deviceKeys.loadOrCreate().wrapper()
        let o: OpenedVault
        do {
            o = try await VaultOpener.open(env, masterPassword: masterPassword, device: device, upgradeKDF: kdf)
        } catch VaultBackupError.wrongPassphrase {
            throw VaultSessionError.wrongPassword
        }
        opened = o
        try await save(o.vault)
        return o.vault
    }

    /// A new vault (`vault`'s content, empty by default) wrapped by this device's key and the master password.
    public func create(masterPassword: String, vault: Vault = Vault()) async throws -> Vault {
        guard masterPassword.count >= MasterPasswordKeyWrapper.minimumLength else {
            throw VaultSessionError.passwordTooShort
        }
        let device = try await deviceKeys.loadOrCreate().wrapper()
        let master = try MasterPasswordKeyWrapper(password: masterPassword, kdf: kdf)
        let env = try await VaultCipher.makeEnvelope(vault, key: VaultCipher.newVaultKey(), wrappers: [device, master],
                                                     metadata: VaultMetadata(revision: 1, updatedAt: now(),
                                                                             deviceName: deviceName))
        try await write(env, opening: device)
        return vault
    }

    /// Saves `vault` (same vault key; every device entry carried over). A change made elsewhere since the load is a
    /// conflict (`VaultStoreError.conflict`), never overwritten.
    public func save(_ vault: Vault) async throws {
        guard let o = opened else { throw VaultSessionError.notOpen }
        let device = try await deviceKeys.loadOrCreate().wrapper()
        let next = try await VaultOpener.nextEnvelope(vault, after: o, wrappers: [], deviceName: deviceName, now: now())
        try await write(next, opening: device)
    }

    /// Re-authentication before showing private keys: true when `masterPassword` opens the current envelope.
    public func verify(masterPassword: String) async throws -> Bool {
        guard let env = envelope else { throw VaultSessionError.notOpen }
        guard env.masterPasswordID != nil else { throw VaultSessionError.cannotOpen }
        do {
            _ = try await VaultOpener.open(env, masterPassword: masterPassword, device: nil, upgradeKDF: kdf)
            return true
        } catch VaultBackupError.wrongPassphrase {
            return false
        }
    }

    /// Forgets the open vault (Lock): keys leave the agent; the next load needs the device key again.
    public func lock() { opened = nil }

    private func write(_ env: VaultEnvelope, opening device: DeviceKeyWrapper) async throws {
        revision = try await store.save(try JSONEncoder().encode(env), ifMatch: revision)
        envelope = env
        guard case .opened(let o) = try await VaultOpener.open(env, wrappers: [device]) else {
            throw VaultSessionError.cannotOpen
        }
        opened = o
    }

    /// A plaintext vault document (the JSON `VaultCipher` seals), for `rsshterm vault import`.
    public static func decodePlain(_ data: Data) throws -> Vault {
        do { return try JSONDecoder().decode(Vault.self, from: data) } catch {
            throw VaultSessionError.badPlainVault("\(error)")
        }
    }
}
