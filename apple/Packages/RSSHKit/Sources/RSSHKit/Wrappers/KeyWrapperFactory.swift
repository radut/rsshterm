import Foundation

/// Turns the settings and the keys this device has into the wrappers that seal and open the vault.
public enum KeyWrapperFactory {
    /// This device's key first, then the iCloud Keychain key while "Sync with iCloud Keychain" is on.
    public static func wrappers(for config: VaultConfig, device: (any KeyWrapper)?,
                                iCloudKeychain: (any KeyWrapper)?) -> [any KeyWrapper] {
        var out: [any KeyWrapper] = []
        if let device { out.append(device) }
        if config.iCloudKeychain, let iCloudKeychain { out.append(iCloudKeychain) }
        return out
    }

    /// Whether a save drops the entry `id`: retired cloud KMS keys always (see `VaultKeyEntries`), the iCloud
    /// Keychain key once the user turned it off.
    public static func dropsEntry(_ id: String, config: VaultConfig) -> Bool {
        switch WrapperKind(id: id) {
        case .retiredCloudKMS: true
        case .iCloudKeychain: !config.iCloudKeychain
        default: false
        }
    }
}
