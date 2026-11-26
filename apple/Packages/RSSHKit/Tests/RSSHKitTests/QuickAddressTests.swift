import Testing
@testable import RSSHKit

@Suite struct QuickAddressTests {
    @Test func userAtHost() {
        #expect(QuickAddress.parse("root@sv1") == QuickAddress(username: "root", host: "sv1", port: nil))
    }

    @Test func userAtHostPortAndTrim() {
        #expect(QuickAddress.parse("  ci@10.0.0.7:2222 ") == QuickAddress(username: "ci", host: "10.0.0.7", port: 2222))
    }

    @Test func sshPrefixIsAccepted() {
        #expect(QuickAddress.parse("ssh root@sv1") == QuickAddress(username: "root", host: "sv1", port: nil))
    }

    @Test func bracketedIPv6WithPort() {
        #expect(QuickAddress.parse("u@[fe80::1]:22") == QuickAddress(username: "u", host: "fe80::1", port: 22))
    }

    @Test(arguments: ["sv1", "root@", "@sv1", "root@sv 1", "ro ot@sv1", "root@sv1:0", "root@sv1:70000",
                      "root@sv1:x", "a@b@c", ""])
    func rejectsNonAddresses(_ text: String) {
        #expect(QuickAddress.parse(text) == nil)
    }

    @Test func displayAndTarget() {
        let address = QuickAddress(username: "root", host: "sv1", port: nil)
        #expect(address.displayName == "root@sv1")
        #expect(address.target == ConnectionTarget(host: "sv1", port: 22, username: "root"))
        #expect(QuickAddress(username: "u", host: "h", port: 2200).displayName == "u@h:2200")
    }

    @Test func matchesSavedServerOnUserHostAndPort() {
        let address = QuickAddress(username: "root", host: "SV1", port: nil)
        #expect(address.matches(Server(name: "a", host: "sv1", username: "root")))
        #expect(!address.matches(Server(name: "b", host: "sv1", port: 2222, username: "root")))
        #expect(!address.matches(Server(name: "c", host: "sv1", username: "admin")))
    }
}
