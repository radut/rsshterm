import Foundation
import Testing
@testable import RSSHKit

@Suite struct ICloudKeychainKeyWrapperTests {
    @Test func wrapsAndUnwrapsWithAnInjectedKeychain() async throws {
        let keychain = MemorySyncedSecretStore()
        let wrapper = try ICloudKeychainKeyWrapper.loadOrCreate(in: keychain)
        #expect(wrapper.id.hasPrefix("icloud-keychain:"))
        #expect(ICloudKeychainKeyWrapper.isICloudID(wrapper.id))
        #expect(WrapperKind(id: wrapper.id) == .iCloudKeychain)
        let key = Data((0..<32).map { UInt8($0) })
        let wrapped = try await wrapper.wrap(key)
        #expect(wrapped != key)
        #expect(try await wrapper.unwrap(wrapped) == key)
    }

    @Test func theKeyIdIsShort() throws {
        let wrapper = try ICloudKeychainKeyWrapper.loadOrCreate(in: MemorySyncedSecretStore())
        let keyID = wrapper.id.dropFirst(ICloudKeychainKeyWrapper.idPrefix.count)
        #expect(keyID.count == 8)
        let hex = keyID.allSatisfy { $0.isHexDigit }
        #expect(hex)
    }

    @Test func loadOrCreateKeepsTheStoredKey() throws {
        let keychain = MemorySyncedSecretStore()
        let first = try ICloudKeychainKeyWrapper.loadOrCreate(in: keychain)
        let again = try ICloudKeychainKeyWrapper.loadOrCreate(in: keychain)
        #expect(first.id == again.id)
        #expect(try ICloudKeychainKeyWrapper.load(from: keychain)?.id == first.id)
        #expect(try ICloudKeychainKeyWrapper.load(from: MemorySyncedSecretStore()) == nil)
    }

    @Test func anotherAppleIDsKeyCannotUnwrap() async throws {
        let mine = try ICloudKeychainKeyWrapper.loadOrCreate(in: MemorySyncedSecretStore())
        let theirs = try ICloudKeychainKeyWrapper(keyID: String(mine.id.dropFirst(16)), secret: Data(repeating: 1, count: 32))
        let wrapped = try await mine.wrap(Data(repeating: 7, count: 32))
        await #expect(throws: (any Error).self) { try await theirs.unwrap(wrapped) }
    }

    @Test func rejectsBadMaterial() {
        #expect(throws: (any Error).self) { try ICloudKeychainKeyWrapper(keyID: "abcd1234", secret: Data(count: 16)) }
        #expect(throws: (any Error).self) { try ICloudKeychainKeyWrapper(keyID: "", secret: Data(count: 32)) }
        #expect(throws: (any Error).self) { try ICloudKeychainKeyWrapper(keyID: "a b", secret: Data(count: 32)) }
    }

    @Test func unreadableStoredMaterialIsAnError() throws {
        let keychain = MemorySyncedSecretStore()
        #expect(try keychain.addIfAbsent(Data("not json".utf8)))
        #expect(throws: (any Error).self) { try ICloudKeychainKeyWrapper.loadOrCreate(in: keychain) }
    }

    @Test func aKeychainThatRefusesIsReported() {
        let keychain = MemorySyncedSecretStore(failure: .unavailable("iCloud Keychain is off"))
        #expect(throws: SyncedSecretStoreError.unavailable("iCloud Keychain is off")) {
            try ICloudKeychainKeyWrapper.loadOrCreate(in: keychain)
        }
    }

    /// Device A seals with its device key and the synced key; device B (same Apple ID, its own device key) has only
    /// the synced key that iCloud Keychain brought over, and opens the vault with it.
    @Test func deviceBOpensDeviceAsVaultWithTheSyncedKeyOnly() async throws {
        let iCloud = MemorySyncedSecretStore()
        let a = DeviceKeyWrapper.newMaterial(), b = DeviceKeyWrapper.newMaterial()
        let deviceA = try DeviceKeyWrapper(tag: a.tag, secret: a.secret)
        let syncedOnA = try ICloudKeychainKeyWrapper.loadOrCreate(in: iCloud)
        let vault = try Vault().addingServer(Server(name: "web", host: "192.0.2.5", username: "root"))
        let envelope = try await VaultCipher.makeEnvelope(vault, key: VaultCipher.newVaultKey(),
                                                          wrappers: [deviceA, syncedOnA],
                                                          metadata: VaultMetadata(revision: 1, updatedAt: Date(), deviceName: "A"))

        let deviceB = try DeviceKeyWrapper(tag: b.tag, secret: b.secret)
        await #expect(throws: VaultError.noUsableWrapper) { try await VaultCipher.unlock(envelope, wrappers: [deviceB]) }
        let syncedOnB = try ICloudKeychainKeyWrapper.loadOrCreate(in: iCloud)
        let (opened, _) = try await VaultCipher.unlock(envelope, wrappers: [deviceB, syncedOnB])
        #expect(opened == vault)
    }

    /// Lost every Apple device: neither a device key nor the iCloud Keychain key, only the recovery passphrase.
    @Test func recoveryPassphraseOpensAVaultWithNeitherDeviceNorICloudKey() async throws {
        let a = DeviceKeyWrapper.newMaterial()
        let device = try DeviceKeyWrapper(tag: a.tag, secret: a.secret)
        let synced = try ICloudKeychainKeyWrapper.loadOrCreate(in: MemorySyncedSecretStore())
        let recovery = try PassphraseKeyWrapper(passphrase: "correct horse battery", rounds: 2_000)
        let vault = try Vault().addingServer(Server(name: "db", host: "192.0.2.9", username: "admin"))
        let envelope = try await VaultCipher.makeEnvelope(vault, key: VaultCipher.newVaultKey(),
                                                          wrappers: [device, synced, recovery],
                                                          metadata: VaultMetadata(revision: 3, updatedAt: Date(), deviceName: "A"))

        let entered = try #require(try PassphraseKeyWrapper.recovery(for: envelope, passphrase: "correct horse battery"))
        let (opened, _) = try await VaultCipher.unlock(envelope, wrappers: [entered])
        #expect(opened == vault)
        let wrong = try #require(try PassphraseKeyWrapper.recovery(for: envelope, passphrase: "wrong horse battery"))
        await #expect(throws: VaultError.noUsableWrapper) { try await VaultCipher.unlock(envelope, wrappers: [wrong]) }
        #expect(envelope.recoveryPassphraseID == recovery.id)
    }

    @Test func noRecoveryEntryMeansNoRecoveryWrapper() async throws {
        let synced = try ICloudKeychainKeyWrapper.loadOrCreate(in: MemorySyncedSecretStore())
        let envelope = try await VaultCipher.makeEnvelope(Vault(), key: VaultCipher.newVaultKey(), wrappers: [synced])
        #expect(try PassphraseKeyWrapper.recovery(for: envelope, passphrase: "correct horse battery") == nil)
        #expect(envelope.recoveryPassphraseID == nil)
    }
}
