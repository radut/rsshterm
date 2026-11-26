import Foundation
import Testing
@testable import RSSHKit

@Suite struct VaultConfigTests {
    @Test func defaultsHaveFaceIDAndICloudKeychainOn() {
        let c = VaultConfig()
        #expect(c.faceIDLock)
        #expect(c.iCloudKeychain)
    }

    @Test func codableRoundTripAndMissingKeysDefault() throws {
        let c = VaultConfig(faceIDLock: false, iCloudKeychain: false)
        #expect(try JSONDecoder().decode(VaultConfig.self, from: JSONEncoder().encode(c)) == c)
        let old = try JSONDecoder().decode(VaultConfig.self, from: Data(#"{"faceIDLock":false}"#.utf8))
        #expect(old == VaultConfig(faceIDLock: false, iCloudKeychain: true))
    }

    @Test func persistsInUserDefaults() throws {
        let suite = "rssh.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VaultConfigStore(defaults: defaults)
        #expect(store.load() == VaultConfig())
        let c = VaultConfig(faceIDLock: false, iCloudKeychain: false)
        store.save(c)
        #expect(VaultConfigStore(defaults: defaults).load() == c)
    }

    @Test func corruptStoredConfigFallsBackToDefaults() throws {
        let suite = "rssh.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("nope".utf8), forKey: VaultConfigStore.key)
        #expect(VaultConfigStore(defaults: defaults).load() == VaultConfig())
    }

    @Test(arguments: [
        ("123-abc.apps.googleusercontent.com", true),
        ("REPLACE_ME.apps.googleusercontent.com", false),
        ("$(GOOGLE_CLIENT_ID)", false),
        ("", false),
    ])
    func googleClientID(_ value: String, _ ok: Bool) {
        #expect(GoogleClientID.isConfigured(value) == ok)
    }

    @Test func googleClientIDMissing() {
        #expect(!GoogleClientID.isConfigured(nil))
    }
}

@Suite struct KeyWrapperFactoryTests {
    let device = FakeKeyWrapper(id: "device:abc")
    let synced = FakeKeyWrapper(id: "icloud-keychain:0a1b2c3d")

    @Test func deviceKeyThenICloudKeychainKey() {
        let ws = KeyWrapperFactory.wrappers(for: VaultConfig(), device: device, iCloudKeychain: synced)
        #expect(ws.map(\.id) == ["device:abc", "icloud-keychain:0a1b2c3d"])
    }

    @Test func iCloudKeychainOffLeavesTheDeviceKey() {
        let ws = KeyWrapperFactory.wrappers(for: VaultConfig(iCloudKeychain: false), device: device, iCloudKeychain: synced)
        #expect(ws.map(\.id) == ["device:abc"])
    }

    @Test func missingKeysAreSkipped() {
        #expect(KeyWrapperFactory.wrappers(for: VaultConfig(), device: nil, iCloudKeychain: nil).isEmpty)
        #expect(KeyWrapperFactory.wrappers(for: VaultConfig(), device: nil, iCloudKeychain: synced).map(\.id) == [synced.id])
    }

    @Test func savesDropRetiredEntriesAndTheICloudKeyWhenOff() {
        let on = VaultConfig(), off = VaultConfig(iCloudKeychain: false)
        #expect(KeyWrapperFactory.dropsEntry("gcp-kms:projects/p", config: on))
        #expect(KeyWrapperFactory.dropsEntry("aws-kms:arn:aws:kms:x", config: on))
        #expect(!KeyWrapperFactory.dropsEntry(synced.id, config: on))
        #expect(KeyWrapperFactory.dropsEntry(synced.id, config: off))
        #expect(!KeyWrapperFactory.dropsEntry(device.id, config: off))
        #expect(!KeyWrapperFactory.dropsEntry("passphrase-pbkdf2-sha256:2000:c2FsdA==", config: off))
    }
}

/// XORs with a byte, so wrapped != plain.
struct FakeKeyWrapper: KeyWrapper {
    let id: String
    func wrap(_ key: Data) async throws -> Data { Data(key.map { $0 ^ 0x5A }) }
    func unwrap(_ wrapped: Data) async throws -> Data { Data(wrapped.map { $0 ^ 0x5A }) }
}
