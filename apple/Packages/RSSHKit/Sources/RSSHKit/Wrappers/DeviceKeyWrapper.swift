import Crypto
import Foundation

/// Wraps the vault key with a random 256-bit key that never leaves this device (the app keeps it in the Keychain,
/// this-device-only). It lets the vault work with no account at all; a cloud wrapper added later only adds its own
/// entry to `VaultEnvelope.wrappedKeys` next to this one.
///
/// The id carries a random per-device tag (`device:<tag>`), so a vault synced from another device shows an entry this
/// device cannot open instead of a failed integrity check under the same name.
public struct DeviceKeyWrapper: KeyWrapper {
    public static let idPrefix = "device:"

    public let id: String
    /// Kept as bytes (SymmetricKey is not Sendable); a key is made per call.
    private let secret: Data

    /// `tag` names this device's wrapping key; `secret` must be 32 bytes.
    public init(tag: String, secret: Data) throws {
        guard secret.count == 32 else { throw VaultError.badKeyLength(secret.count) }
        guard !tag.isEmpty, !tag.contains(where: \.isWhitespace) else {
            throw KeyWrapperError.notConfigured("The device key has no valid name.")
        }
        id = Self.idPrefix + tag
        self.secret = secret
    }

    /// True for an envelope entry written by some device's wrapper (this one or another).
    public static func isDeviceID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// A fresh tag and secret for a new device key.
    public static func newMaterial() -> (tag: String, secret: Data) {
        let tag = UUID().uuidString.lowercased()
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return (tag, secret)
    }

    public func wrap(_ key: Data) async throws -> Data {
        guard let combined = try AES.GCM.seal(key, using: SymmetricKey(data: secret), authenticating: Data(id.utf8)).combined else {
            throw KeyWrapperError.invalidResponse("The device key could not seal the vault key.")
        }
        return combined
    }

    public func unwrap(_ wrapped: Data) async throws -> Data {
        let box = try AES.GCM.SealedBox(combined: wrapped)
        return try AES.GCM.open(box, using: SymmetricKey(data: secret), authenticating: Data(id.utf8))
    }
}
