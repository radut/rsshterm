import Crypto
import Foundation

/// Wraps the vault key with a random 256-bit key kept in iCloud Keychain (`SyncedSecretStore`), so every device on
/// the same Apple ID with iCloud Keychain on can open a vault it finds in iCloud, with no other account.
/// The id carries a short random key id (`icloud-keychain:<8 hex>`), so an envelope shows which synced key sealed it.
public struct ICloudKeychainKeyWrapper: KeyWrapper {
    public static let idPrefix = "icloud-keychain:"

    public let id: String
    /// Kept as bytes (SymmetricKey is not Sendable); a key is made per call.
    private let secret: Data

    /// What the Keychain item holds.
    private struct Material: Codable {
        let keyID: String
        let secret: Data
    }

    /// `keyID` names the synced key; `secret` must be 32 bytes.
    public init(keyID: String, secret: Data) throws {
        guard secret.count == 32 else { throw VaultError.badKeyLength(secret.count) }
        guard !keyID.isEmpty, !keyID.contains(where: { $0.isWhitespace || $0 == ":" }) else {
            throw KeyWrapperError.notConfigured("The iCloud Keychain key has no valid name.")
        }
        id = Self.idPrefix + keyID
        self.secret = secret
    }

    public static func isICloudID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The synced key, or nil while there is none in `store`.
    public static func load(from store: any SyncedSecretStore) throws -> ICloudKeychainKeyWrapper? {
        guard let data = try store.read() else { return nil }
        guard let material = try? JSONDecoder().decode(Material.self, from: data) else {
            throw KeyWrapperError.invalidResponse("The iCloud Keychain key could not be read.")
        }
        return try ICloudKeychainKeyWrapper(keyID: material.keyID, secret: material.secret)
    }

    /// The synced key; a new one is stored when there is none. Another device's key that arrived first wins.
    public static func loadOrCreate(in store: any SyncedSecretStore) throws -> ICloudKeychainKeyWrapper {
        if let stored = try load(from: store) { return stored }
        let keyID = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        if try store.addIfAbsent(try JSONEncoder().encode(Material(keyID: keyID, secret: secret))) {
            return try ICloudKeychainKeyWrapper(keyID: keyID, secret: secret)
        }
        guard let stored = try load(from: store) else {
            throw SyncedSecretStoreError.unavailable("The iCloud Keychain key could not be stored.")
        }
        return stored
    }

    public func wrap(_ key: Data) async throws -> Data {
        guard let combined = try AES.GCM.seal(key, using: SymmetricKey(data: secret), authenticating: Data(id.utf8)).combined else {
            throw KeyWrapperError.invalidResponse("The iCloud Keychain key could not seal the vault key.")
        }
        return combined
    }

    public func unwrap(_ wrapped: Data) async throws -> Data {
        let box = try AES.GCM.SealedBox(combined: wrapped)
        return try AES.GCM.open(box, using: SymmetricKey(data: secret), authenticating: Data(id.utf8))
    }
}
