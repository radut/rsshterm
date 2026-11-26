import Crypto
import Foundation
import Testing
@testable import RSSHKit

/// A wrapper that XORs with a fixed pad: enough to prove the envelope plumbing without a cloud.
struct FakeWrapper: KeyWrapper {
    let id: String
    let pad: UInt8
    func wrap(_ key: Data) async throws -> Data { Data(key.map { $0 ^ pad }) }
    func unwrap(_ wrapped: Data) async throws -> Data { Data(wrapped.map { $0 ^ pad }) }
}

@Suite struct VaultCipherTests {
    let vault = Vault(
        groups: [ServerGroup(name: "Home")],
        servers: [Server(name: "pi", host: "10.0.0.2", username: "root")],
        credentials: [Credential(label: "root", kind: .password("s3cret"))])

    @Test func sealOpenRoundTrip() throws {
        let key = VaultCipher.newVaultKey()
        let sealed = try VaultCipher.seal(vault, key: key)
        #expect(try VaultCipher.open(sealed, key: key) == vault)
        #expect(!String(decoding: sealed, as: UTF8.self).contains("s3cret"))
    }

    @Test func wrongKeyFails() throws {
        let sealed = try VaultCipher.seal(vault, key: VaultCipher.newVaultKey())
        #expect(throws: (any Error).self) { try VaultCipher.open(sealed, key: VaultCipher.newVaultKey()) }
    }

    @Test func anyWrapperUnlocks() async throws {
        let gcp = FakeWrapper(id: "gcp", pad: 0x5A), aws = FakeWrapper(id: "aws", pad: 0xA5)
        let env = try await VaultCipher.makeEnvelope(vault, key: VaultCipher.newVaultKey(), wrappers: [gcp, aws])
        #expect(Set(env.wrappedKeys.keys) == ["gcp", "aws"])
        #expect(try await VaultCipher.unlock(env, wrappers: [aws]).0 == vault)
        #expect(try await VaultCipher.unlock(env, wrappers: [gcp]).0 == vault)
    }

    @Test func noMatchingWrapper() async throws {
        let env = try await VaultCipher.makeEnvelope(vault, key: VaultCipher.newVaultKey(),
                                                     wrappers: [FakeWrapper(id: "gcp", pad: 1)])
        await #expect(throws: VaultError.noUsableWrapper) {
            try await VaultCipher.unlock(env, wrappers: [FakeWrapper(id: "aws", pad: 1)])
        }
    }

    @Test func memoryStoreDetectsConflict() async throws {
        let store = MemoryVaultStore()
        let r1 = try await store.save(Data([1]), ifMatch: nil)
        _ = try await store.save(Data([2]), ifMatch: r1)
        await #expect(throws: VaultStoreError.conflict(currentRevision: "2")) {
            try await store.save(Data([3]), ifMatch: r1)
        }
    }
}
