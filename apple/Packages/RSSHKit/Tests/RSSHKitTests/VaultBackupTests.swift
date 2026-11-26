import Foundation
import Testing
@testable import RSSHKit

@Suite struct VaultBackupTests {
    let vault = Vault(servers: [Server(name: "web", host: "192.0.2.7", username: "root")])
    let metadata = VaultMetadata(revision: 4, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func exportsAndOpensWithThePassphrase() async throws {
        let data = try await VaultBackup.export(vault, passphrase: "correct horse", metadata: metadata, rounds: 2_000)
        let envelope = try JSONDecoder().decode(VaultEnvelope.self, from: data)
        #expect(envelope.wrappedKeys.keys.allSatisfy(PassphraseKeyWrapper.isPassphraseID))
        #expect(try await VaultBackup.open(data, passphrase: "correct horse") == vault)
    }

    @Test func wrongPassphraseIsRefused() async throws {
        let data = try await VaultBackup.export(vault, passphrase: "correct horse", metadata: metadata, rounds: 2_000)
        await #expect(throws: VaultBackupError.wrongPassphrase) {
            try await VaultBackup.open(data, passphrase: "wrong horse!")
        }
    }

    @Test func shortPassphraseAndOtherFilesAreRefused() async throws {
        await #expect(throws: VaultBackupError.weakPassphrase) {
            try await VaultBackup.export(vault, passphrase: "short", metadata: metadata)
        }
        await #expect(throws: VaultBackupError.notABackup) {
            try await VaultBackup.open(Data("{}".utf8), passphrase: "whatever1")
        }
    }
}

@Suite struct MirroredVaultStoreTests {
    let file = MemoryVaultStore(id: "local")
    let keychain = MemoryVaultStore(id: "keychain")
    var store: MirroredVaultStore { MirroredVaultStore(primary: file, mirror: keychain) }

    func envelope(_ revision: UInt64) async throws -> Data {
        let e = try await VaultCipher.makeEnvelope(Vault(), key: VaultCipher.newVaultKey(), wrappers: [],
                                                   metadata: VaultMetadata(revision: revision, updatedAt: Date()))
        return try JSONEncoder().encode(e)
    }

    @Test func savesWriteBothCopies() async throws {
        let data = try await envelope(1)
        let rev = try await store.save(data, ifMatch: nil)
        #expect(try await file.load() == StoredVault(data: data, revision: rev))
        #expect(try await keychain.load()?.data == data)
        let next = try await envelope(2)
        _ = try await store.save(next, ifMatch: rev)
        #expect(try await keychain.load()?.data == next)
    }

    /// A reinstall: the file is gone, the Keychain copy is not.
    @Test func missingFileIsRestoredFromTheCopy() async throws {
        let data = try await envelope(3)
        _ = try await keychain.save(data, ifMatch: nil)
        let loaded = try #require(try await store.load())
        #expect(loaded.data == data)
        #expect(try await file.load()?.data == data)
        #expect(try await file.load()?.revision == loaded.revision)
    }

    @Test func theNewerRevisionWinsAndRepairsTheOther() async throws {
        let old = try await envelope(1), new = try await envelope(2)
        _ = try await file.save(old, ifMatch: nil)
        _ = try await keychain.save(new, ifMatch: nil)
        #expect(try await store.load()?.data == new)
        #expect(try await file.load()?.data == new)

        let newer = try await envelope(5)
        let current = try await file.load()?.revision
        _ = try await file.save(newer, ifMatch: current)
        #expect(try await store.load()?.data == newer)
        #expect(try await keychain.load()?.data == newer)
    }

    @Test func fileAloneIsCopiedToTheMirror() async throws {
        let data = try await envelope(1)
        _ = try await file.save(data, ifMatch: nil)
        #expect(try await store.load()?.data == data)
        #expect(try await keychain.load()?.data == data)
    }
}

@Suite struct PBKDF2Tests {
    /// Known PBKDF2-HMAC-SHA256 vectors ("password" / "salt").
    @Test(arguments: [
        (1, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
        (2, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
        (4096, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
    ])
    func vectors(rounds: Int, hex: String) {
        let out = PBKDF2.sha256(password: Data("password".utf8), salt: Data("salt".utf8), rounds: rounds)
        #expect(out.map { String(format: "%02x", $0) }.joined() == hex)
    }
}
