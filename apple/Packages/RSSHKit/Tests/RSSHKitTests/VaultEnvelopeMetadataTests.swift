import Foundation
import Testing
@testable import RSSHKit

@Suite struct VaultEnvelopeMetadataTests {
    @Test func oldEnvelopeWithoutMetadataDecodes() throws {
        let json = #"{"format":"rssh-vault-v1","wrappedKeys":{},"sealed":"AAEC"}"#
        let env = try JSONDecoder().decode(VaultEnvelope.self, from: Data(json.utf8))
        #expect(env.updatedAt == nil)
        #expect(env.deviceName == nil)
        #expect(env.sealed == Data([0, 1, 2]))
    }

    @Test func metadataRoundTrips() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let env = VaultEnvelope(wrappedKeys: ["k": Data([9])], sealed: Data([1]), updatedAt: when, deviceName: "iPhone")
        let back = try JSONDecoder().decode(VaultEnvelope.self, from: JSONEncoder().encode(env))
        #expect(back == env)
        #expect(back.updatedAt == when)
        #expect(back.deviceName == "iPhone")
    }
}
