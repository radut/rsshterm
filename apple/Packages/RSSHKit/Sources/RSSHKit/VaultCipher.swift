import Crypto
import Foundation

/// Unwraps/wraps the 256-bit vault key with another key: this device's key, the iCloud Keychain key, or the master
/// password. The vault key itself never leaves the device unwrapped.
public protocol KeyWrapper: Sendable {
    /// Stable id stored next to the wrapped key, e.g. "icloud-keychain:0a1b2c3d" (see `WrapperKind`).
    var id: String { get }
    func wrap(_ key: Data) async throws -> Data
    func unwrap(_ wrapped: Data) async throws -> Data
}

/// What is written to storage: the vault sealed with AES-256-GCM, plus the vault key wrapped by one or more
/// `KeyWrapper`s (any one of them can open it).
public struct VaultEnvelope: Codable, Hashable, Sendable {
    public static let format = "rssh-vault-v1"

    public var format: String
    /// `KeyWrapper.id` -> wrapped vault key.
    public var wrappedKeys: [String: Data]
    /// AES.GCM combined representation (nonce | ciphertext | tag).
    public var sealed: Data
    /// When the writing device sealed this envelope; `VaultSync` picks the newest. Optional so envelopes written before
    /// the field existed still decode. Covered by the GCM tag when `revision` is set (see `VaultMetadata`).
    public var updatedAt: Date?
    /// The writing device's name, shown when two sources conflict.
    public var deviceName: String?
    /// Grows by one with every save. When set, it, `updatedAt` and `deviceName` are bound into the AES-GCM tag
    /// (`VaultMetadata.aad`), so a store cannot fake them, and a reader can refuse an older revision than it has seen.
    /// nil only in envelopes written before it existed (opened with the plain format AAD).
    public var revision: UInt64?

    public init(wrappedKeys: [String: Data], sealed: Data, updatedAt: Date? = nil, deviceName: String? = nil,
                revision: UInt64? = nil) {
        self.format = VaultEnvelope.format
        self.wrappedKeys = wrappedKeys
        self.sealed = sealed
        self.updatedAt = updatedAt
        self.deviceName = deviceName
        self.revision = revision
    }
}

public enum VaultError: Error, Equatable, LocalizedError {
    case unknownFormat(String)
    case noUsableWrapper
    case badKeyLength(Int)
    /// Every entry is a Google Cloud KMS or AWS KMS key, which this app no longer uses.
    case retiredKeysOnly

    public var errorDescription: String? {
        switch self {
        case .unknownFormat(let format): "The vault has a format this app does not know (\(format))."
        case .noUsableWrapper: "None of the keys set up here opens this vault."
        case .badKeyLength: "The vault key has the wrong length."
        case .retiredKeysOnly:
            "This vault was sealed with Google Cloud/AWS keys that are no longer supported; open it from a backup."
        }
    }
}

/// Envelope encryption of the `Vault` document.
public enum VaultCipher {
    static let aad = Data(VaultEnvelope.format.utf8)

    public static func newVaultKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// Legacy sealing (format-only AAD), as in envelopes without a revision.
    public static func seal(_ vault: Vault, key: SymmetricKey) throws -> Data {
        try seal(vault, key: key, aad: aad)
    }

    public static func open(_ sealed: Data, key: SymmetricKey) throws -> Vault {
        try open(sealed, key: key, aad: aad)
    }

    static func seal(_ vault: Vault, key: SymmetricKey, aad: Data) throws -> Data {
        let plain = try JSONEncoder.sorted.encode(vault)
        return try AES.GCM.seal(plain, using: key, authenticating: aad).combined!
    }

    static func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws -> Vault {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plain = try AES.GCM.open(box, using: key, authenticating: aad)
        return try JSONDecoder().decode(Vault.self, from: plain)
    }

    /// Opens an envelope; with a revision, its revision/updatedAt/deviceName must match the tag.
    public static func open(_ envelope: VaultEnvelope, key: SymmetricKey) throws -> Vault {
        guard envelope.format == VaultEnvelope.format else { throw VaultError.unknownFormat(envelope.format) }
        guard let metadata = VaultMetadata(envelope) else { return try open(envelope.sealed, key: key) }
        return try open(envelope.sealed, key: key, aad: metadata.aad)
    }

    /// An envelope sealed with `metadata` bound into the tag; `wrappedKeys` are carried over as they are.
    public static func envelope(_ vault: Vault, key: SymmetricKey, wrappedKeys: [String: Data],
                                metadata: VaultMetadata) throws -> VaultEnvelope {
        VaultEnvelope(wrappedKeys: wrappedKeys, sealed: try seal(vault, key: key, aad: metadata.aad),
                      updatedAt: metadata.updatedAt, deviceName: metadata.deviceName, revision: metadata.revision)
    }

    /// Seals `vault` and wraps its key with every wrapper; with `metadata`, bound into the tag.
    public static func makeEnvelope(_ vault: Vault, key: SymmetricKey, wrappers: [any KeyWrapper],
                                    metadata: VaultMetadata? = nil) async throws -> VaultEnvelope {
        let raw = key.withUnsafeBytes { Data($0) }
        var wrapped: [String: Data] = [:]
        for w in wrappers { wrapped[w.id] = try await w.wrap(raw) }
        guard let metadata else { return VaultEnvelope(wrappedKeys: wrapped, sealed: try seal(vault, key: key)) }
        return try envelope(vault, key: key, wrappedKeys: wrapped, metadata: metadata)
    }

    /// Recovers the vault key with the first wrapper that has an entry in the envelope and can unwrap it.
    public static func unlock(_ envelope: VaultEnvelope, wrappers: [any KeyWrapper]) async throws -> (Vault, SymmetricKey) {
        guard envelope.format == VaultEnvelope.format else { throw VaultError.unknownFormat(envelope.format) }
        for w in wrappers {
            guard let wrapped = envelope.wrappedKeys[w.id], let raw = try? await w.unwrap(wrapped) else { continue }
            guard raw.count == 32 else { throw VaultError.badKeyLength(raw.count) }
            let key = SymmetricKey(data: raw)
            return (try open(envelope, key: key), key)
        }
        throw envelope.hasOnlyRetiredKeys ? VaultError.retiredKeysOnly : VaultError.noUsableWrapper
    }
}

extension JSONEncoder {
    /// Deterministic output, so the same vault always serialises the same way (diffable, cache-friendly).
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
