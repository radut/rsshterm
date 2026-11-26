import Crypto
import Foundation
import Testing
@testable import RSSHKit

/// The envelope's revision, updatedAt and deviceName are authenticated (AES-GCM AAD), so a store cannot replay an
/// older envelope under a newer timestamp or revision.
@Suite struct VaultReplayTests {
    let key = VaultCipher.newVaultKey()
    let vault = Vault(groups: [ServerGroup(name: "Home")])
    let meta = VaultMetadata(revision: 7, updatedAt: Date(timeIntervalSince1970: 1_800_000_000.123_456), deviceName: "iPhone")

    func envelope() throws -> VaultEnvelope {
        try VaultCipher.envelope(vault, key: key, wrappedKeys: ["k": Data([1])], metadata: meta)
    }

    @Test func sealedWithMetadataOpens() throws {
        let env = try envelope()
        #expect(env.revision == 7)
        #expect(env.deviceName == "iPhone")
        #expect(try VaultCipher.open(env, key: key) == vault)
    }

    @Test func survivesAJSONRoundTrip() throws {
        let back = try JSONDecoder().decode(VaultEnvelope.self, from: JSONEncoder().encode(try envelope()))
        #expect(try VaultCipher.open(back, key: key) == vault)
    }

    @Test func tamperedUpdatedAtIsDetected() throws {
        var env = try envelope()
        env.updatedAt = env.updatedAt!.addingTimeInterval(3600)
        #expect(throws: (any Error).self) { try VaultCipher.open(env, key: key) }
    }

    @Test(arguments: [1e300, -1e300])
    func absurdUpdatedAtFailsWithoutTrapping(_ seconds: Double) throws {
        var env = try envelope()
        env.updatedAt = Date(timeIntervalSince1970: seconds)
        #expect(throws: (any Error).self) { try VaultCipher.open(env, key: key) }
        #expect(VaultMetadata.milliseconds(Date(timeIntervalSince1970: seconds)) == "invalid")
        #expect(VaultMetadata.milliseconds(Date(timeIntervalSince1970: 1.5)) == "1500")
    }

    @Test func tamperedRevisionIsDetected() throws {
        var env = try envelope()
        env.revision = 8
        #expect(throws: (any Error).self) { try VaultCipher.open(env, key: key) }
    }

    @Test func tamperedDeviceNameIsDetected() throws {
        var env = try envelope()
        env.deviceName = "Mallory"
        #expect(throws: (any Error).self) { try VaultCipher.open(env, key: key) }
    }

    @Test func strippedRevisionIsDetected() throws {
        var env = try envelope()
        env.revision = nil
        env.updatedAt = nil
        env.deviceName = nil
        #expect(throws: (any Error).self) { try VaultCipher.open(env, key: key) }
    }

    @Test func legacyEnvelopeWithoutRevisionStillOpens() throws {
        let legacy = VaultEnvelope(wrappedKeys: [:], sealed: try VaultCipher.seal(vault, key: key))
        #expect(legacy.revision == nil)
        #expect(try VaultCipher.open(legacy, key: key) == vault)
    }

    @Test func unlockChecksTheMetadataToo() async throws {
        struct Plain: KeyWrapper {
            let id = "plain"
            func wrap(_ key: Data) async throws -> Data { key }
            func unwrap(_ wrapped: Data) async throws -> Data { wrapped }
        }
        var env = try await VaultCipher.makeEnvelope(vault, key: key, wrappers: [Plain()], metadata: meta)
        #expect(try await VaultCipher.unlock(env, wrappers: [Plain()]).0 == vault)
        env.updatedAt = .distantFuture
        await #expect(throws: (any Error).self) { try await VaultCipher.unlock(env, wrappers: [Plain()]) }
    }
}
