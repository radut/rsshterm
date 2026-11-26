import Foundation
import Testing
@testable import RSSHKit

/// Envelopes and settings written while Google Cloud KMS, AWS KMS and the S3 vault store existed.
@Suite struct RetiredKeysTests {
    static let gcpID = "gcp-kms:projects/p-12345/locations/europe-west1/keyRings/r/cryptoKeys/vault"
    static let awsID = "aws-kms:arn:aws:kms:eu-central-1:123456789012:key/abcd"

    func device() throws -> DeviceKeyWrapper {
        let m = DeviceKeyWrapper.newMaterial()
        return try DeviceKeyWrapper(tag: m.tag, secret: m.secret)
    }

    @Test func kindsOfEntries() throws {
        #expect(WrapperKind(id: Self.gcpID) == .retiredCloudKMS)
        #expect(WrapperKind(id: Self.awsID) == .retiredCloudKMS)
        #expect(WrapperKind(id: try device().id) == .device)
        #expect(WrapperKind(id: "passphrase-pbkdf2-sha256:2000:c2FsdA==") == .passphrase)
        #expect(WrapperKind(id: "icloud-keychain:0a1b2c3d") == .iCloudKeychain)
        #expect(WrapperKind(id: "something-new:x") == .other)
    }

    /// An envelope with KMS entries next to the device entry still opens with the device key.
    @Test func kmsEnvelopeStillOpensWithTheDeviceKey() async throws {
        let device = try device()
        let key = VaultCipher.newVaultKey()
        var envelope = try await VaultCipher.makeEnvelope(Vault(), key: key, wrappers: [device])
        envelope.wrappedKeys[Self.gcpID] = Data(repeating: 1, count: 60)
        envelope.wrappedKeys[Self.awsID] = Data(repeating: 2, count: 60)
        let (vault, _) = try await VaultCipher.unlock(envelope, wrappers: [device])
        #expect(vault == Vault())
        #expect(!envelope.hasOnlyRetiredKeys)
    }

    @Test func kmsOnlyEnvelopeGivesTheClearError() async throws {
        let envelope = VaultEnvelope(wrappedKeys: [Self.gcpID: Data(count: 60), Self.awsID: Data(count: 60)],
                                     sealed: Data(count: 40))
        #expect(envelope.hasOnlyRetiredKeys)
        await #expect(throws: VaultError.retiredKeysOnly) { try await VaultCipher.unlock(envelope, wrappers: [try device()]) }
        let message = VaultError.retiredKeysOnly.errorDescription ?? ""
        #expect(message == "This vault was sealed with Google Cloud/AWS keys that are no longer supported; open it from a backup.")
    }

    @Test func anEmptyEnvelopeIsNotRetiredOnly() {
        #expect(!VaultEnvelope(wrappedKeys: [:], sealed: Data()).hasOnlyRetiredKeys)
    }

    @Test func saveDropsStaleKMSEntries() throws {
        let device = try device().id
        let wrapped = [device: Data([1]), Self.gcpID: Data([2]), Self.awsID: Data([3]), "icloud-keychain:0a1b2c3d": Data([4])]
        let kept = VaultKeyEntries.carriedOver(wrapped)
        #expect(Set(kept.keys) == [device, "icloud-keychain:0a1b2c3d"])
        let withoutICloud = VaultKeyEntries.carriedOver(wrapped, dropping: { WrapperKind(id: $0) == .iCloudKeychain })
        #expect(Set(withoutICloud.keys) == [device])
    }

    @Test func oldConfigWithKMSAndS3FieldsDecodes() throws {
        let old = #"""
        {"gcpKMSKeyName":"projects/p/locations/l/keyRings/r/cryptoKeys/k","awsRoleARN":"arn:aws:iam::123456789012:role/r",
         "awsKMSKeyARN":"arn:aws:kms:eu-central-1:123456789012:key/k","awsRegion":"eu-central-1","faceIDLock":false,
         "s3Bucket":"my-vault","s3Region":"eu-west-1","s3Key":"rssh/vault.json"}
        """#
        let config = try JSONDecoder().decode(VaultConfig.self, from: Data(old.utf8))
        #expect(config == VaultConfig(faceIDLock: false, iCloudKeychain: true))
        let encoded = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!encoded.contains("s3Bucket"))
        #expect(!encoded.contains("KMS"))
    }

    @Test func configStoreReportsRetiredSettingsUntilSavedAgain() throws {
        let suite = "rssh.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"s3Bucket":"my-vault","awsRoleARN":"","faceIDLock":true}"#.utf8), forKey: VaultConfigStore.key)
        let store = VaultConfigStore(defaults: defaults)
        #expect(store.retiredSettings == ["s3Bucket"])
        store.save(store.load())
        #expect(store.retiredSettings.isEmpty)
    }
}
