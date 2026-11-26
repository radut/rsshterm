import Crypto
import _CryptoExtras
import Foundation

/// How a master password becomes a wrapping key. The parameters are part of the envelope entry's id, so an entry alone
/// is enough to derive the same key again on another device.
public enum MasterPasswordKDF: Hashable, Sendable {
    /// scrypt (RFC 7914) through swift-crypto's `_CryptoExtras` (BoringSSL `EVP_PBE_scrypt`): N = 2^logN, r, p.
    case scrypt(logN: Int, blockSize: Int, parallelism: Int)
    /// PBKDF2-HMAC-SHA256: entries written before scrypt (recovery passphrase, encrypted backups).
    case pbkdf2SHA256(rounds: Int)

    /// OWASP's minimum for scrypt: N = 2^17 (128 MiB), r = 8, p = 1.
    public static let `default` = MasterPasswordKDF.scrypt(logN: 17, blockSize: 8, parallelism: 1)

    /// Bounds an entry's parameters must be in: a store that can write entries must not make an open allocate
    /// gigabytes or spin for hours. Tests use the low ends.
    static let scryptLogN = 10...20
    static let scryptBlockSize = 1...16
    static let scryptParallelism = 1...4
    static let pbkdf2Rounds = 1_000...10_000_000
    /// scrypt needs 128 * r * N bytes: at most 256 MiB (twice the default), whatever the single settings are.
    static let scryptMaxMemory = 256 << 20

    var isValid: Bool {
        switch self {
        case let .scrypt(logN, r, p):
            Self.scryptLogN.contains(logN) && Self.scryptBlockSize.contains(r) && Self.scryptParallelism.contains(p)
                && 128 * r * (1 << logN) <= Self.scryptMaxMemory
        case let .pbkdf2SHA256(rounds): Self.pbkdf2Rounds.contains(rounds)
        }
    }

    /// `length` bytes derived from `password` and `salt`.
    public func derive(password: Data, salt: Data, length: Int = 32) throws -> Data {
        switch self {
        case let .scrypt(logN, r, p):
            let key = try KDF.Scrypt.deriveKey(from: password, salt: salt, outputByteCount: length, rounds: 1 << logN,
                                               blockSize: r, parallelism: p)
            return key.withUnsafeBytes { Data($0) }
        case let .pbkdf2SHA256(rounds):
            return PBKDF2.sha256(password: password, salt: salt, rounds: rounds)
        }
    }
}

/// Wraps the vault key with a key derived from the user's master password. It opens the vault on a device that has no
/// key of its own yet (a new phone, the Linux or Mac desktop): after that open, the device adds its own key's entry on
/// the next save (`VaultOpener`). Also used for the encrypted backup file (`VaultBackup`).
///
/// Ids:
/// - `master-scrypt:<logN>:<r>:<p>:<salt base64>`: written now.
/// - `passphrase-pbkdf2-sha256:<rounds>:<salt base64>`: written before the rename ("recovery passphrase"); still opened,
///   and `VaultOpener` replaces it with a scrypt entry on the next save.
public struct MasterPasswordKeyWrapper: KeyWrapper {
    public static let scryptPrefix = "master-scrypt:"
    public static let pbkdf2Prefix = "passphrase-pbkdf2-sha256:"
    /// Kept for `VaultBackup` and the old API: PBKDF2 rounds for a new PBKDF2 entry.
    public static let defaultRounds = 600_000
    public static let minimumLength = 8

    public let id: String
    public let kdf: MasterPasswordKDF
    /// The derived key as bytes (SymmetricKey is not Sendable).
    private let derived: Data

    /// A new entry with a random salt; throws `VaultBackupError.weakPassphrase` for a short password.
    public init(password: String, kdf: MasterPasswordKDF = .default) throws {
        guard password.count >= Self.minimumLength else { throw VaultBackupError.weakPassphrase }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        try self.init(password: password, salt: salt, kdf: kdf)
    }

    /// The wrapper an envelope entry `id` was made with; nil when `id` is not a master password entry, throws
    /// `VaultBackupError.notABackup` for an entry whose parameters are out of bounds.
    public init?(id: String, password: String) throws {
        guard let (kdf, salt) = try Self.parse(id) else { return nil }
        try self.init(password: password, salt: salt, kdf: kdf)
    }

    private init(password: String, salt: Data, kdf: MasterPasswordKDF) throws {
        guard kdf.isValid, !salt.isEmpty else { throw VaultBackupError.notABackup }
        derived = try kdf.derive(password: Data(password.utf8), salt: salt)
        self.kdf = kdf
        let salt64 = salt.base64EncodedString()
        switch kdf {
        case let .scrypt(logN, r, p): id = "\(Self.scryptPrefix)\(logN):\(r):\(p):\(salt64)"
        case let .pbkdf2SHA256(rounds): id = "\(Self.pbkdf2Prefix)\(rounds):\(salt64)"
        }
    }

    private static func parse(_ id: String) throws -> (MasterPasswordKDF, Data)? {
        let kdf: MasterPasswordKDF
        let fields: [Substring]
        if id.hasPrefix(scryptPrefix) {
            fields = id.dropFirst(scryptPrefix.count).split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 4, let logN = Int(fields[0]), let r = Int(fields[1]), let p = Int(fields[2]) else {
                return nil
            }
            kdf = .scrypt(logN: logN, blockSize: r, parallelism: p)
        } else if id.hasPrefix(pbkdf2Prefix) {
            fields = id.dropFirst(pbkdf2Prefix.count).split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2, let rounds = Int(fields[0]) else { return nil }
            kdf = .pbkdf2SHA256(rounds: rounds)
        } else {
            return nil
        }
        guard let salt = Data(base64Encoded: String(fields[fields.count - 1])) else { return nil }
        guard kdf.isValid else { throw VaultBackupError.notABackup }
        return (kdf, salt)
    }

    public static func isMasterPasswordID(_ id: String) -> Bool { id.hasPrefix(scryptPrefix) || id.hasPrefix(pbkdf2Prefix) }

    /// True for an entry made with something weaker than `MasterPasswordKDF.default` (PBKDF2): worth re-wrapping.
    public var isOutdated: Bool {
        if case .pbkdf2SHA256 = kdf { return true }
        return false
    }

    public func wrap(_ key: Data) async throws -> Data {
        guard let combined = try AES.GCM.seal(key, using: SymmetricKey(data: derived),
                                              authenticating: Data(id.utf8)).combined else {
            throw VaultBackupError.notABackup
        }
        return combined
    }

    public func unwrap(_ wrapped: Data) async throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            return try AES.GCM.open(box, using: SymmetricKey(data: derived), authenticating: Data(id.utf8))
        } catch {
            throw VaultBackupError.wrongPassphrase
        }
    }
}

// MARK: - The old names ("recovery passphrase"), kept so the iOS app and older call sites build unchanged.

/// The old name of `MasterPasswordKeyWrapper`.
public typealias PassphraseKeyWrapper = MasterPasswordKeyWrapper

extension MasterPasswordKeyWrapper {
    /// The old PBKDF2 entry (`passphrase-pbkdf2-sha256:`), as the encrypted backup and the old app write it.
    public init(passphrase: String, rounds: Int = MasterPasswordKeyWrapper.defaultRounds) throws {
        guard passphrase.count >= Self.minimumLength else { throw VaultBackupError.weakPassphrase }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        // Rounds outside the bounds an entry may carry throw `notABackup`: such an entry would not open again.
        try self.init(password: passphrase, salt: salt, kdf: .pbkdf2SHA256(rounds: rounds))
    }

    public init?(id: String, passphrase: String) throws {
        try self.init(id: id, password: passphrase)
    }

    public static func isPassphraseID(_ id: String) -> Bool { isMasterPasswordID(id) }
}
