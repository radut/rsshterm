import Crypto
import Foundation
import Testing
@testable import RSSHKit

@Suite struct MasterPasswordKeyWrapperTests {
    /// Cheap scrypt parameters, so the suite stays fast; the defaults are checked separately.
    static let fastScrypt = MasterPasswordKDF.scrypt(logN: 10, blockSize: 8, parallelism: 1)
    static let key = Data(repeating: 7, count: 32)

    @Test func defaultIsScryptWithAtLeastOWASPCost() {
        guard case let .scrypt(logN, r, p) = MasterPasswordKDF.default else {
            Issue.record("the default KDF is not scrypt")
            return
        }
        #expect(logN >= 17)
        #expect(r == 8)
        #expect(p == 1)
    }

    @Test func scryptRoundTripsAndStoresItsParametersInTheID() async throws {
        let w = try MasterPasswordKeyWrapper(password: "correct horse battery", kdf: Self.fastScrypt)
        #expect(w.id.hasPrefix("master-scrypt:10:8:1:"))
        let wrapped = try await w.wrap(Self.key)
        let again = try #require(try MasterPasswordKeyWrapper(id: w.id, password: "correct horse battery"))
        #expect(again.kdf == Self.fastScrypt)
        #expect(try await again.unwrap(wrapped) == Self.key)
    }

    @Test func wrongPasswordIsReported() async throws {
        let w = try MasterPasswordKeyWrapper(password: "correct horse battery", kdf: Self.fastScrypt)
        let wrapped = try await w.wrap(Self.key)
        let wrong = try #require(try MasterPasswordKeyWrapper(id: w.id, password: "incorrect horse"))
        await #expect(throws: VaultBackupError.wrongPassphrase) { try await wrong.unwrap(wrapped) }
    }

    @Test func shortPasswordIsRefused() {
        #expect(throws: VaultBackupError.weakPassphrase) {
            try MasterPasswordKeyWrapper(password: "short", kdf: Self.fastScrypt)
        }
    }

    @Test func oldPBKDF2EntriesStillOpen() async throws {
        // Written by the app before the rename: the old type name, the old id prefix.
        let old = try PassphraseKeyWrapper(passphrase: "correct horse battery", rounds: 2_000)
        #expect(old.id.hasPrefix("passphrase-pbkdf2-sha256:2000:"))
        let wrapped = try await old.wrap(Self.key)
        let opened = try #require(try MasterPasswordKeyWrapper(id: old.id, password: "correct horse battery"))
        #expect(opened.kdf == .pbkdf2SHA256(rounds: 2_000))
        #expect(opened.isOutdated)
        #expect(try await opened.unwrap(wrapped) == Self.key)
    }

    @Test func pbkdf2RoundsComeFromTheEntry() throws {
        let a = try #require(try MasterPasswordKeyWrapper(id: "passphrase-pbkdf2-sha256:1000:c2FsdHNhbHQ=", password: "pw-pw-pw-pw"))
        #expect(a.kdf == .pbkdf2SHA256(rounds: 1_000))
    }

    @Test func idsOfBothFormatsAreMasterPasswordEntries() {
        #expect(MasterPasswordKeyWrapper.isMasterPasswordID("master-scrypt:17:8:1:AAAA"))
        #expect(MasterPasswordKeyWrapper.isMasterPasswordID("passphrase-pbkdf2-sha256:600000:AAAA"))
        #expect(!MasterPasswordKeyWrapper.isMasterPasswordID("device:abc"))
        #expect(WrapperKind(id: "master-scrypt:17:8:1:AAAA") == .passphrase)
        #expect(PassphraseKeyWrapper.isPassphraseID("master-scrypt:17:8:1:AAAA"))
    }

    @Test func otherIDsAreNotParsed() throws {
        #expect(try MasterPasswordKeyWrapper(id: "device:abc", password: "pw-pw-pw-pw") == nil)
        #expect(try MasterPasswordKeyWrapper(id: "master-scrypt:junk", password: "pw-pw-pw-pw") == nil)
    }

    /// A store that can write entries could otherwise make every open allocate gigabytes or spin for hours.
    @Test(arguments: [
        "master-scrypt:30:8:1:c2FsdHNhbHQ=",
        "master-scrypt:20:16:1:c2FsdHNhbHQ=",   // each setting in range, 2 GiB together
        "master-scrypt:19:8:1:c2FsdHNhbHQ=",
        "master-scrypt:17:64:1:c2FsdHNhbHQ=",
        "master-scrypt:17:8:9:c2FsdHNhbHQ=",
        "master-scrypt:4:8:1:c2FsdHNhbHQ=",
        "passphrase-pbkdf2-sha256:0:c2FsdHNhbHQ=",
        "passphrase-pbkdf2-sha256:99000000:c2FsdHNhbHQ=",
    ])
    func outOfRangeParametersAreRefused(id: String) {
        #expect(throws: VaultBackupError.notABackup) { try MasterPasswordKeyWrapper(id: id, password: "pw-pw-pw-pw") }
    }

    @Test func envelopePrefersTheScryptEntry() {
        let env = VaultEnvelope(wrappedKeys: ["passphrase-pbkdf2-sha256:1:AA==": Data(), "master-scrypt:10:8:1:AA==": Data(),
                                              "device:x": Data()], sealed: Data())
        #expect(env.masterPasswordID == "master-scrypt:10:8:1:AA==")
        #expect(env.recoveryPassphraseID == env.masterPasswordID)
    }

    /// RFC 7914 §12 vector 2, through the same swift-crypto call the wrapper uses.
    @Test func scryptMatchesRFC7914() throws {
        let out = try MasterPasswordKDF.scrypt(logN: 10, blockSize: 8, parallelism: 16)
            .derive(password: Data("password".utf8), salt: Data("NaCl".utf8), length: 64)
        #expect(out.map { String(format: "%02x", $0) }.joined().hasPrefix("fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e773"))
    }
}
