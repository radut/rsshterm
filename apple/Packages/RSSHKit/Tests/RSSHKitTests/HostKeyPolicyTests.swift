import Crypto
import Foundation
import Testing
@testable import RSSHKit

/// SSH wire string: uint32 length + bytes.
func sshString(_ bytes: [UInt8]) -> [UInt8] {
    let n = UInt32(bytes.count)
    return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + bytes
}

func sshString(_ s: String) -> [UInt8] { sshString(Array(s.utf8)) }

@Suite struct HostKeyFingerprintTests {
    let blob = Data(sshString("ssh-ed25519") + sshString([UInt8](repeating: 7, count: 32)))

    @Test func fingerprintIsUnpaddedBase64OfSHA256() {
        let expected = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        #expect(HostKeyFingerprint.sha256(blob: blob) == expected)
        #expect(!expected.hasSuffix("="))
    }

    @Test func parsesAnOpenSSHPublicKeyLine() throws {
        let line = "ssh-ed25519 \(blob.base64EncodedString()) root@box"
        let parsed = try HostKeyFingerprint.parse(openSSHPublicKey: line)
        #expect(parsed.keyType == "ssh-ed25519")
        #expect(parsed.fingerprint == HostKeyFingerprint.sha256(blob: blob))
    }

    @Test func rejectsGarbage() {
        #expect(throws: HostKeyFingerprint.ParseError.self) { try HostKeyFingerprint.parse(openSSHPublicKey: "nope") }
        #expect(throws: HostKeyFingerprint.ParseError.self) {
            try HostKeyFingerprint.parse(openSSHPublicKey: "ssh-ed25519 !!!notbase64")
        }
    }

    @Test func rejectsAKeyWhoseBlobTypeDiffersFromTheLabel() {
        #expect(throws: HostKeyFingerprint.ParseError.self) {
            try HostKeyFingerprint.parse(openSSHPublicKey: "ssh-rsa \(blob.base64EncodedString())")
        }
    }
}

@Suite struct HostKeyPolicyTests {
    let pinned = KnownHost(host: "pi.local", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:aaa")

    @Test func unknownHostAsks() {
        let presented = KnownHost(host: "new.local", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:x")
        #expect(HostKeyPolicy.evaluate(presented, against: [pinned]) == .ask)
        #expect(HostKeyPolicy.evaluate(presented, against: []) == .ask)
    }

    @Test func matchingKeyIsAccepted() {
        #expect(HostKeyPolicy.evaluate(pinned, against: [pinned]) == .accept)
    }

    @Test func hostMatchIsCaseInsensitive() {
        let presented = KnownHost(host: "PI.Local", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:aaa")
        #expect(HostKeyPolicy.evaluate(presented, against: [pinned]) == .accept)
    }

    @Test func changedKeyIsRefused() {
        let presented = KnownHost(host: "pi.local", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:evil")
        #expect(HostKeyPolicy.evaluate(presented, against: [pinned]) == .refuse(expected: pinned))
    }

    @Test func differentKeyTypeForAPinnedHostIsRefused() {
        // A downgrade to another algorithm must not silently re-ask.
        let presented = KnownHost(host: "pi.local", port: 22, keyType: "ssh-rsa", fingerprint: "SHA256:bbb")
        #expect(HostKeyPolicy.evaluate(presented, against: [pinned]) == .refuse(expected: pinned))
    }

    @Test func samehostOtherPortIsADifferentHost() {
        let presented = KnownHost(host: "pi.local", port: 2222, keyType: "ssh-ed25519", fingerprint: "SHA256:zzz")
        #expect(HostKeyPolicy.evaluate(presented, against: [pinned]) == .ask)
    }

    @Test func trustingAddsAndReplacesWithoutMutating() {
        let original = [pinned]
        let other = KnownHost(host: "nas", port: 22, keyType: "ssh-rsa", fingerprint: "SHA256:n")
        let added = HostKeyPolicy.trusting(other, in: original)
        #expect(added == [pinned, other])
        #expect(original == [pinned])
        let rotated = KnownHost(host: "PI.local", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:new")
        #expect(HostKeyPolicy.trusting(rotated, in: added) == [other, rotated])
    }

    @Test func pinningAddsOnlyWhileTheHostIsUnknown() {
        let fresh = KnownHost(host: "nas", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:n")
        #expect(HostKeyPolicy.pinning(fresh, in: [pinned]) == [pinned, fresh])
        #expect(HostKeyPolicy.pinning(pinned, in: [pinned]) == [pinned])
        let rival = KnownHost(host: "pi.local", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:other")
        #expect(HostKeyPolicy.pinning(rival, in: [pinned]) == nil)
    }

    @Test func replacingSwapsTheChangedKeyForTheSameEndpointOnly() {
        let other = KnownHost(host: "nas", port: 22, keyType: "ssh-rsa", fingerprint: "SHA256:n")
        let rotated = KnownHost(host: "pi.local", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:new")
        let replaced = HostKeyPolicy.replacing(pinned, with: rotated, in: [pinned, other])
        #expect(replaced == [other, rotated])
        #expect(HostKeyPolicy.evaluate(rotated, against: replaced ?? []) == .accept)
    }

    @Test func replacingRefusesWhenThePinChangedMeanwhile() {
        let rotated = KnownHost(host: "pi.local", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:new")
        let third = KnownHost(host: "pi.local", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:third")
        #expect(HostKeyPolicy.replacing(pinned, with: rotated, in: [third]) == nil)
        #expect(HostKeyPolicy.replacing(pinned, with: rotated, in: []) == nil)
    }

    @Test func trustDateIsKeptButNotPartOfIdentity() throws {
        let dated = pinned.trusted(at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(dated == pinned)
        #expect(Set([dated, pinned]).count == 1)
        let decoded = try JSONDecoder().decode(KnownHost.self, from: try JSONEncoder().encode(dated))
        #expect(decoded.addedAt == dated.addedAt)
        let old = #"{"host":"h","port":22,"keyType":"ssh-ed25519","fingerprint":"SHA256:f"}"#
        #expect(try JSONDecoder().decode(KnownHost.self, from: Data(old.utf8)).addedAt == nil)
    }

    @Test func forgettingRemovesTheHost() {
        let other = KnownHost(host: "nas", port: 22, keyType: "ssh-rsa", fingerprint: "SHA256:n")
        #expect(HostKeyPolicy.forgetting(host: "pi.local", port: 22, in: [pinned, other]) == [other])
    }
}

@Suite struct VaultKnownHostsTests {
    @Test func oldVaultJSONWithoutKnownHostsDecodes() throws {
        let json = #"{"version":1,"groups":[],"servers":[],"credentials":[]}"#
        let vault = try JSONDecoder().decode(Vault.self, from: Data(json.utf8))
        #expect(vault.knownHosts.isEmpty)
        #expect(vault.version == 1)
    }

    @Test func knownHostsRoundTrip() throws {
        var vault = Vault()
        vault.knownHosts = [KnownHost(host: "h", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:f")]
        let decoded = try JSONDecoder().decode(Vault.self, from: try JSONEncoder().encode(vault))
        #expect(decoded == vault)
    }
}
