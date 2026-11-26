import Foundation
import Testing
@testable import RSSHKit

@Suite struct RDPCertificatePinTests {
    let fp = "ab:CD:01:23"
    let other = "ff:ee:dd:cc"

    @Test func firstSightAsksThenAPinAcceptsAndAChangeRefuses() {
        let d = RemoteDesktop(name: "Win", kind: .rdp, host: "10.0.0.5")
        #expect(RDPCertificatePolicy.evaluate(presented: fp, pinned: d.pinnedCertificate) == .askToTrust)
        #expect(RDPCertificatePolicy.evaluate(presented: fp, pinned: "AB:cd:01:23") == .accept)   // case-insensitive
        #expect(RDPCertificatePolicy.evaluate(presented: other, pinned: fp) == .changed(expected: "ab:cd:01:23"))
        #expect(RDPCertificatePolicy.evaluate(presented: "", pinned: nil) == .refuse)
    }

    @Test func pinIsStoredInTheEntryAndSurvivesTheVault() throws {
        let d = RemoteDesktop(name: "Win", kind: .rdp, host: "10.0.0.5")
        let vault = try Vault().addingRemoteDesktop(d).pinningRDPCertificate(fp, for: d.id)
        #expect(vault.remoteDesktops.first?.pinnedCertificate == "ab:cd:01:23")
        let back = try JSONDecoder().decode(Vault.self, from: JSONEncoder().encode(vault))
        #expect(back.remoteDesktops.first?.pinnedCertificate == "ab:cd:01:23")
        #expect(throws: VaultEditError.unknownRemoteDesktop) { try vault.pinningRDPCertificate(fp, for: UUID()) }
    }

    @Test func movingTheEntryToAnotherHostForgetsThePin() throws {
        var d = RemoteDesktop(name: "Win", kind: .rdp, host: "10.0.0.5")
        let pinned = try Vault().addingRemoteDesktop(d).pinningRDPCertificate(fp, for: d.id)
        d = try #require(pinned.remoteDesktops.first)
        d.host = "10.0.0.6"
        let moved = try pinned.updatingRemoteDesktop(d)
        #expect(moved.remoteDesktops.first?.pinnedCertificate == nil)
        var renamed = try #require(pinned.remoteDesktops.first)
        renamed.name = "Win 11"
        #expect(try pinned.updatingRemoteDesktop(renamed).remoteDesktops.first?.pinnedCertificate == "ab:cd:01:23")
    }
}
