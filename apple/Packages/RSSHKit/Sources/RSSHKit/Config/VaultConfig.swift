import Foundation

/// The non-secret vault settings: whether the iCloud Keychain key wraps the vault key too, and whether Face ID guards
/// the cached key.
public struct VaultConfig: Codable, Hashable, Sendable {
    public var faceIDLock: Bool
    /// "Sync with iCloud Keychain": the vault key is also wrapped by a key in iCloud Keychain, so the user's other
    /// Apple devices can open the vault. On unless the user turned it off.
    public var iCloudKeychain: Bool

    public init(faceIDLock: Bool = true, iCloudKeychain: Bool = true) {
        self.faceIDLock = faceIDLock
        self.iCloudKeychain = iCloudKeychain
    }

    private enum CodingKeys: String, CodingKey {
        case faceIDLock, iCloudKeychain
    }

    /// Missing keys take their defaults, so settings saved by an older build still load; the retired cloud KMS and
    /// S3 fields such a build wrote are ignored (and gone at the next save).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(faceIDLock: try c.decodeIfPresent(Bool.self, forKey: .faceIDLock) ?? true,
                  iCloudKeychain: try c.decodeIfPresent(Bool.self, forKey: .iCloudKeychain) ?? true)
    }

    /// Shown when the Keychain refuses even this device's key, so no vault can be made.
    public static let noDeviceKeyMessage = "The vault key could not be stored on this iPhone (the Keychain refused it)."
}

/// Keeps `VaultConfig` as JSON in UserDefaults (it holds no secrets).
public struct VaultConfigStore {
    public static let key = "rssh.vaultConfig"
    /// Fields of the Google Cloud KMS, AWS KMS and Amazon S3 settings older builds saved.
    public static let retiredFields = ["gcpKMSKeyName", "awsRoleARN", "awsKMSKeyARN", "awsRegion", "s3Bucket", "s3Region"]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved settings, or the defaults when none are saved or they cannot be read.
    public func load() -> VaultConfig {
        guard let data = defaults.data(forKey: Self.key),
              let config = try? JSONDecoder().decode(VaultConfig.self, from: data) else { return VaultConfig() }
        return config
    }

    public func save(_ config: VaultConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The retired fields the stored settings still fill in (non-empty), in `retiredFields` order.
    public var retiredSettings: [String] {
        guard let data = defaults.data(forKey: Self.key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Self.retiredFields.filter { (object[$0] as? String)?.isEmpty == false }
    }
}
