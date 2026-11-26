import Crypto
import Foundation

/// A vault opened from an envelope, with what the next save has to change in the envelope's entries.
public struct OpenedVault: Sendable {
    public let vault: Vault
    public let envelope: VaultEnvelope
    /// The vault key's 32 bytes (SymmetricKey is not Sendable).
    public let rawKey: Data
    /// Wrappers whose entries the next save adds: this device's key after a master-password open, a scrypt entry
    /// replacing an old PBKDF2 one.
    public let pendingWrappers: [any KeyWrapper]
    /// Entries the next save drops (the old PBKDF2 entry once its scrypt replacement is pending).
    public let droppedEntryIDs: Set<String>

    public var key: SymmetricKey { SymmetricKey(data: rawKey) }
}

/// How an envelope opened with the keys this device has.
public enum VaultOpenResult: Sendable {
    case opened(OpenedVault)
    /// None of this device's keys opens it, but it has a master password entry (`id`): ask for the password, then call
    /// `VaultOpener.open(_:masterPassword:device:)`. A new device (desktop, new phone) always lands here first.
    case needsMasterPassword(id: String)
}

/// What a save does with the master password entry.
public enum MasterPasswordChange: Sendable {
    case keep
    /// Replace any master password entry with one for this password.
    case set(String, kdf: MasterPasswordKDF = .default)
    case remove
}

/// Opening the vault on any device, and the "new device" flow: no key of this device opens the envelope -> the user
/// types the master password -> the vault opens -> the next save adds this device's key entry, so later opens need no
/// password. The envelope format is unchanged; any device can still open the result.
public enum VaultOpener {
    /// Opens `envelope` with the first of `wrappers` that has an entry and can unwrap it.
    public static func open(_ envelope: VaultEnvelope, wrappers: [any KeyWrapper]) async throws -> VaultOpenResult {
        do {
            let (vault, key) = try await VaultCipher.unlock(envelope, wrappers: wrappers)
            return .opened(OpenedVault(vault: vault, envelope: envelope, rawKey: key.withUnsafeBytes { Data($0) },
                                       pendingWrappers: [], droppedEntryIDs: []))
        } catch VaultError.noUsableWrapper {
            guard let id = envelope.masterPasswordID else { throw VaultError.noUsableWrapper }
            return .needsMasterPassword(id: id)
        }
    }

    /// Opens `envelope` with the master password; `device` (this device's key, when it has one) is queued for the next
    /// save. An old PBKDF2 entry is queued to be replaced by one made with `upgradeKDF`.
    /// Throws `VaultBackupError.wrongPassphrase` for a wrong password, `VaultError.noUsableWrapper` with no entry.
    public static func open(_ envelope: VaultEnvelope, masterPassword: String, device: (any KeyWrapper)?,
                            upgradeKDF: MasterPasswordKDF = .default) async throws -> OpenedVault {
        guard envelope.format == VaultEnvelope.format else { throw VaultError.unknownFormat(envelope.format) }
        guard let wrapper = try MasterPasswordKeyWrapper.forEnvelope(envelope, password: masterPassword),
              let wrapped = envelope.wrappedKeys[wrapper.id] else { throw VaultError.noUsableWrapper }
        let raw = try await wrapper.unwrap(wrapped)
        guard raw.count == 32 else { throw VaultError.badKeyLength(raw.count) }
        let vault = try VaultCipher.open(envelope, key: SymmetricKey(data: raw))
        var pending: [any KeyWrapper] = []
        if let device { pending.append(device) }
        var dropped: Set<String> = []
        if wrapper.isOutdated, upgradeKDF != wrapper.kdf {
            pending.append(try MasterPasswordKeyWrapper(password: masterPassword, kdf: upgradeKDF))
            dropped.insert(wrapper.id)
        }
        return OpenedVault(vault: vault, envelope: envelope, rawKey: raw, pendingWrappers: pending, droppedEntryIDs: dropped)
    }

    /// The envelope for the next save of `vault` (same vault key): the entries of `opened.envelope` carried over (minus
    /// retired and dropped ones), the pending wrappers and `wrappers` added, the revision one higher, `now` and
    /// `deviceName` bound into the tag.
    ///
    /// `rotateKey`: seal with a new vault key, wrapped only by the pending wrappers and `wrappers` (entries of other
    /// devices cannot be re-wrapped here and are dropped: those devices open the next envelope with the master password
    /// or the iCloud Keychain key). Use it when the master password is changed or removed: without it, anyone who knew
    /// the old password and kept an old envelope still has the vault key and can open later envelopes too.
    /// Reopen the result with `open(_:wrappers:)` to get the new key.
    public static func nextEnvelope(_ vault: Vault, after opened: OpenedVault, wrappers: [any KeyWrapper],
                                    deviceName: String?, now: Date, masterPassword: MasterPasswordChange = .keep,
                                    rotateKey: Bool = false) async throws -> VaultEnvelope {
        var adding = opened.pendingWrappers + wrappers
        let replacesMaster: Bool
        switch masterPassword {
        case .keep:
            replacesMaster = false
        case .remove:
            replacesMaster = true
            adding.removeAll { MasterPasswordKeyWrapper.isMasterPasswordID($0.id) }
        case let .set(password, kdf):
            replacesMaster = true
            adding.removeAll { MasterPasswordKeyWrapper.isMasterPasswordID($0.id) }
            adding.append(try MasterPasswordKeyWrapper(password: password, kdf: kdf))
        }
        let dropped = opened.droppedEntryIDs
        var entries = rotateKey ? [:] : VaultKeyEntries.carriedOver(opened.envelope.wrappedKeys) { id in
            dropped.contains(id) || (replacesMaster && MasterPasswordKeyWrapper.isMasterPasswordID(id))
        }
        let key = rotateKey ? VaultCipher.newVaultKey() : opened.key
        let raw = key.withUnsafeBytes { Data($0) }
        for w in adding { entries[w.id] = try await w.wrap(raw) }
        guard !entries.isEmpty else { throw VaultError.noUsableWrapper }
        let metadata = VaultMetadata(revision: (opened.envelope.revision ?? 0) + 1, updatedAt: now, deviceName: deviceName)
        return try VaultCipher.envelope(vault, key: key, wrappedKeys: entries, metadata: metadata)
    }
}
