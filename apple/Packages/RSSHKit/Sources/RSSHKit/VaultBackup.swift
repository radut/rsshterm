import Crypto
import Foundation

public enum VaultBackupError: Error, Equatable, Sendable, LocalizedError {
    case weakPassphrase
    case wrongPassphrase
    case notABackup

    public var errorDescription: String? {
        switch self {
        case .weakPassphrase: "Use a passphrase of at least \(PassphraseKeyWrapper.minimumLength) characters."
        case .wrongPassphrase: "The passphrase does not open this backup."
        case .notABackup: "This file is not an rSshTerm vault backup."
        }
    }
}

/// An encrypted backup file to move the vault to a new phone: an ordinary `VaultEnvelope` sealed with a fresh vault
/// key that only a passphrase wraps. The device's own vault key never leaves the device.
public enum VaultBackup {
    public static let fileExtension = "rsshvault"

    /// The backup file's bytes (JSON).
    public static func export(_ vault: Vault, passphrase: String, metadata: VaultMetadata,
                              rounds: Int = PassphraseKeyWrapper.defaultRounds) async throws -> Data {
        let wrapper = try PassphraseKeyWrapper(passphrase: passphrase, rounds: rounds)
        let envelope = try await VaultCipher.makeEnvelope(vault, key: VaultCipher.newVaultKey(), wrappers: [wrapper],
                                                          metadata: metadata)
        return try JSONEncoder().encode(envelope)
    }

    /// The vault in a backup file; throws `VaultBackupError` for a wrong passphrase or a file that is not a backup.
    public static func open(_ data: Data, passphrase: String) async throws -> Vault {
        guard let envelope = try? JSONDecoder().decode(VaultEnvelope.self, from: data),
              let entry = envelope.wrappedKeys.first(where: { PassphraseKeyWrapper.isPassphraseID($0.key) }),
              let wrapper = try PassphraseKeyWrapper(id: entry.key, passphrase: passphrase)
        else { throw VaultBackupError.notABackup }
        let raw = try await wrapper.unwrap(entry.value)
        do {
            return try VaultCipher.open(envelope, key: SymmetricKey(data: raw))
        } catch {
            throw VaultBackupError.notABackup
        }
    }
}
