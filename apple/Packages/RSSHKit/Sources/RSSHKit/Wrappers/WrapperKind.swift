import Foundation

/// What kind of key an envelope entry (`VaultEnvelope.wrappedKeys`) was wrapped with, read from its id.
public enum WrapperKind: Equatable, Sendable {
    case device
    case iCloudKeychain
    /// A master password entry (scrypt, or the older PBKDF2 "recovery passphrase").
    case passphrase
    /// Google Cloud KMS or AWS KMS: no longer supported. Such entries are kept until the next save, which drops them.
    case retiredCloudKMS
    case other

    /// Id prefixes of the cloud KMS wrappers that are gone.
    public static let retiredPrefixes = ["gcp-kms:", "aws-kms:"]

    public init(id: String) {
        if DeviceKeyWrapper.isDeviceID(id) {
            self = .device
        } else if ICloudKeychainKeyWrapper.isICloudID(id) {
            self = .iCloudKeychain
        } else if PassphraseKeyWrapper.isPassphraseID(id) {
            self = .passphrase
        } else if Self.retiredPrefixes.contains(where: id.hasPrefix) {
            self = .retiredCloudKMS
        } else {
            self = .other
        }
    }
}

extension VaultEnvelope {
    /// True when the envelope has entries and every one of them is a retired cloud KMS key: nothing here can open it.
    public var hasOnlyRetiredKeys: Bool {
        !wrappedKeys.isEmpty && wrappedKeys.keys.allSatisfy { WrapperKind(id: $0) == .retiredCloudKMS }
    }

    /// The id of the master password entry, if the envelope has one; a scrypt entry before an old PBKDF2 one.
    public var masterPasswordID: String? {
        let ids = wrappedKeys.keys.filter(MasterPasswordKeyWrapper.isMasterPasswordID).sorted()
        return ids.first(where: { $0.hasPrefix(MasterPasswordKeyWrapper.scryptPrefix) }) ?? ids.first
    }

    /// The old name of `masterPasswordID`.
    public var recoveryPassphraseID: String? { masterPasswordID }
}

/// The envelope entries a save carries over to the next revision.
public enum VaultKeyEntries {
    /// `wrapped` without retired cloud KMS entries and without those `dropping` names (a key the user turned off).
    public static func carriedOver(_ wrapped: [String: Data],
                                   dropping: (String) -> Bool = { _ in false }) -> [String: Data] {
        wrapped.filter { id, _ in WrapperKind(id: id) != .retiredCloudKMS && !dropping(id) }
    }
}

extension MasterPasswordKeyWrapper {
    /// The wrapper for the master password entry of `envelope`, made from what the user typed; nil when the envelope
    /// has no such entry. A wrong password gives a wrapper that cannot unwrap.
    public static func forEnvelope(_ envelope: VaultEnvelope, password: String) throws -> MasterPasswordKeyWrapper? {
        guard let id = envelope.masterPasswordID else { return nil }
        return try MasterPasswordKeyWrapper(id: id, password: password)
    }

    /// The old name of `forEnvelope(_:password:)`.
    public static func recovery(for envelope: VaultEnvelope, passphrase: String) throws -> MasterPasswordKeyWrapper? {
        try forEnvelope(envelope, password: passphrase)
    }
}
