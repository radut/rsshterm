import Crypto
import Foundation
import Testing
@testable import RSSHKit

@Suite struct VaultOpenerTests {
    static let fast = MasterPasswordKDF.scrypt(logN: 10, blockSize: 8, parallelism: 1)
    static let password = "correct horse battery"

    static func device() throws -> DeviceKeyWrapper {
        let m = DeviceKeyWrapper.newMaterial()
        return try DeviceKeyWrapper(tag: m.tag, secret: m.secret)
    }

    static func vault() -> Vault {
        var v = Vault()
        v.servers = [Server(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!, name: "alpha", host: "alpha.example", username: "ops")]
        return v
    }

    /// The first device: its own key plus a master password.
    static func firstEnvelope(device: DeviceKeyWrapper) async throws -> VaultEnvelope {
        let master = try MasterPasswordKeyWrapper(password: password, kdf: fast)
        return try await VaultCipher.makeEnvelope(vault(), key: VaultCipher.newVaultKey(), wrappers: [device, master],
                                                  metadata: VaultMetadata(revision: 1, updatedAt: Date()))
    }

    @Test func ownDeviceKeyOpensWithoutAPassword() async throws {
        let a = try Self.device()
        let env = try await Self.firstEnvelope(device: a)
        let result = try await VaultOpener.open(env, wrappers: [a])
        guard case .opened(let opened) = result else { Issue.record("not opened"); return }
        #expect(opened.vault.servers.map(\.name) == ["alpha"])
        #expect(opened.pendingWrappers.isEmpty)
    }

    @Test func newDeviceIsAskedForTheMasterPassword() async throws {
        let env = try await Self.firstEnvelope(device: try Self.device())
        let result = try await VaultOpener.open(env, wrappers: [try Self.device()])
        guard case .needsMasterPassword(let id) = result else { Issue.record("not asked"); return }
        #expect(id == env.masterPasswordID)
    }

    @Test func noMasterPasswordAndNoKeyIsAnError() async throws {
        let env = try await VaultCipher.makeEnvelope(Self.vault(), key: VaultCipher.newVaultKey(), wrappers: [try Self.device()])
        await #expect(throws: VaultError.noUsableWrapper) { try await VaultOpener.open(env, wrappers: [try Self.device()]) }
    }

    @Test func masterPasswordOpensAndQueuesThisDevicesKey() async throws {
        let a = try Self.device(), b = try Self.device()
        let env = try await Self.firstEnvelope(device: a)
        let opened = try await VaultOpener.open(env, masterPassword: Self.password, device: b)
        #expect(opened.vault == Self.vault())
        #expect(opened.pendingWrappers.map(\.id) == [b.id])
    }

    @Test func wrongMasterPasswordIsReported() async throws {
        let env = try await Self.firstEnvelope(device: try Self.device())
        await #expect(throws: VaultBackupError.wrongPassphrase) {
            try await VaultOpener.open(env, masterPassword: "not the password", device: try Self.device())
        }
    }

    @Test func nextSaveAddsThisDeviceAndKeepsTheOthers() async throws {
        let a = try Self.device(), b = try Self.device()
        let env = try await Self.firstEnvelope(device: a)
        let opened = try await VaultOpener.open(env, masterPassword: Self.password, device: b)
        var edited = opened.vault
        edited.servers.append(Server(name: "beta", host: "beta.example", username: "ops"))
        let next = try await VaultOpener.nextEnvelope(edited, after: opened, wrappers: [b], deviceName: "laptop", now: Date())
        #expect(next.revision == 2)
        #expect(Set(next.wrappedKeys.keys) == Set(env.wrappedKeys.keys).union([b.id]))
        // A still opens it with its own key, B now without the password.
        guard case .opened(let byA) = try await VaultOpener.open(next, wrappers: [a]) else { Issue.record("A"); return }
        guard case .opened(let byB) = try await VaultOpener.open(next, wrappers: [b]) else { Issue.record("B"); return }
        #expect(byA.vault.servers.count == 2)
        #expect(byB.vault == byA.vault)
    }

    @Test func oldPBKDF2MasterPasswordIsUpgradedOnTheNextSave() async throws {
        let a = try Self.device(), b = try Self.device()
        let old = try PassphraseKeyWrapper(passphrase: Self.password, rounds: 2_000)
        let env = try await VaultCipher.makeEnvelope(Self.vault(), key: VaultCipher.newVaultKey(), wrappers: [a, old],
                                                     metadata: VaultMetadata(revision: 4, updatedAt: Date()))
        let opened = try await VaultOpener.open(env, masterPassword: Self.password, device: b, upgradeKDF: Self.fast)
        let next = try await VaultOpener.nextEnvelope(opened.vault, after: opened, wrappers: [b], deviceName: nil, now: Date())
        #expect(next.wrappedKeys[old.id] == nil)
        let newID = try #require(next.masterPasswordID)
        #expect(newID.hasPrefix("master-scrypt:10:8:1:"))
        // The new entry opens with the same password on a third device.
        let c = try Self.device()
        let third = try await VaultOpener.open(next, masterPassword: Self.password, device: c)
        #expect(third.vault == Self.vault())
    }

    @Test func settingAMasterPasswordReplacesTheOldOne() async throws {
        let a = try Self.device()
        let env = try await Self.firstEnvelope(device: a)
        guard case .opened(let opened) = try await VaultOpener.open(env, wrappers: [a]) else { Issue.record("open"); return }
        let changed = try await VaultOpener.nextEnvelope(opened.vault, after: opened, wrappers: [a], deviceName: nil,
                                                         now: Date(),
                                                         masterPassword: .set("a new long password", kdf: Self.fast))
        let ids = changed.wrappedKeys.keys.filter(MasterPasswordKeyWrapper.isMasterPasswordID)
        #expect(ids.count == 1)
        await #expect(throws: VaultBackupError.wrongPassphrase) {
            try await VaultOpener.open(changed, masterPassword: Self.password, device: try Self.device())
        }
        let removed = try await VaultOpener.nextEnvelope(opened.vault, after: opened, wrappers: [a], deviceName: nil,
                                                         now: Date(), masterPassword: .remove)
        #expect(removed.masterPasswordID == nil)
    }

    @Test func changingThePasswordWithRotationLocksOutTheOldPassword() async throws {
        let a = try Self.device(), b = try Self.device()
        let env = try await Self.firstEnvelope(device: a)
        // B joined with the password; someone who knows the old password keeps `env`.
        let leaked = try await VaultOpener.open(env, masterPassword: Self.password, device: nil)
        guard case .opened(let opened) = try await VaultOpener.open(env, wrappers: [a]) else { Issue.record("open"); return }
        let rotated = try await VaultOpener.nextEnvelope(opened.vault, after: opened, wrappers: [a], deviceName: nil,
                                                         now: Date(), masterPassword: .set("a new long password", kdf: Self.fast),
                                                         rotateKey: true)
        // The old vault key no longer opens the new envelope.
        #expect(throws: (any Error).self) { try VaultCipher.open(rotated, key: leaked.key) }
        #expect(rotated.wrappedKeys.keys.contains(a.id))
        #expect(!rotated.wrappedKeys.keys.contains(b.id))
        guard case .opened = try await VaultOpener.open(rotated, wrappers: [a]) else { Issue.record("A"); return }
        let byB = try await VaultOpener.open(rotated, masterPassword: "a new long password", device: b)
        #expect(byB.vault == Self.vault())
    }

    @Test func removingEveryEntryIsRefused() async throws {
        let a = try Self.device()
        let env = try await Self.firstEnvelope(device: a)
        let opened = try await VaultOpener.open(env, masterPassword: Self.password, device: nil)
        await #expect(throws: VaultError.noUsableWrapper) {
            try await VaultOpener.nextEnvelope(opened.vault, after: opened, wrappers: [], deviceName: nil, now: Date(),
                                               masterPassword: .remove, rotateKey: true)
        }
    }
}
