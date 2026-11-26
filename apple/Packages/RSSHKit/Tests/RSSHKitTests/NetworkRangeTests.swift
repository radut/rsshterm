import Foundation
import Testing
@testable import RSSHKit

@Suite struct NetworkRangeTests {
    private func hosts(_ text: String) throws -> [String] {
        try NetworkRange(parsing: text).hosts.map(\.description)
    }

    @Test func ipv4ParsesDottedDecimalOnly() {
        #expect(IPv4("192.0.2.1")?.description == "192.0.2.1")
        #expect(IPv4("0.0.0.0")?.value == 0)
        for bad in ["192.0.2", "192.0.2.256", "192.0.2.1.5", "a.b.c.d", "192.0.2.-1", "192.0.2.1 ", "", "1..2.3", "1234.0.0.1"] {
            #expect(IPv4(bad) == nil, "\(bad)")
        }
    }

    @Test func cidrLeavesOutNetworkAndBroadcast() throws {
        let list = try hosts("192.0.2.0/24")
        #expect(list.count == 254)
        #expect(list.first == "192.0.2.1")
        #expect(list.last == "192.0.2.254")
        #expect(try hosts("192.0.2.77/30") == ["192.0.2.77", "192.0.2.78"])
        #expect(try hosts("192.0.2.8/31") == ["192.0.2.8", "192.0.2.9"])
        #expect(try hosts("192.0.2.8/32") == ["192.0.2.8"])
    }

    @Test func aBareNetworkAddressMeansItsSlash24() throws {
        let list = try hosts("192.0.2.0")
        #expect(list.count == 254)
        #expect(list.first == "192.0.2.1" && list.last == "192.0.2.254")
        #expect(try hosts("192.0.2.0/32") == ["192.0.2.0"])
    }

    @Test func rangesBySuffixOrFullAddress() throws {
        #expect(try hosts("192.0.2.10-12") == ["192.0.2.10", "192.0.2.11", "192.0.2.12"])
        let wide = try hosts("192.0.2.250-192.0.3.2")
        #expect(wide.first == "192.0.2.250")
        #expect(wide.last == "192.0.3.2")
        #expect(wide.count == 9)
        #expect(try hosts("192.0.2.10-192.0.2.60").count == 51)
    }

    @Test func listsBySpaceOrCommaWithoutDuplicates() throws {
        #expect(try hosts("192.0.2.1, 192.0.2.3 192.0.2.1,192.0.2.2-3") == ["192.0.2.1", "192.0.2.3", "192.0.2.2"])
    }

    @Test func refusesGarbageAndBackwardRanges() {
        #expect(throws: NetworkRangeError.empty) { try NetworkRange(parsing: "  , ") }
        #expect(throws: NetworkRangeError.invalid("example.com")) { try NetworkRange(parsing: "example.com") }
        #expect(throws: NetworkRangeError.invalid("192.0.2.50-10")) { try NetworkRange(parsing: "192.0.2.50-10") }
        #expect(throws: NetworkRangeError.invalid("192.0.2.0/33")) { try NetworkRange(parsing: "192.0.2.0/33") }
        #expect(throws: NetworkRangeError.invalid("192.0.2.1-300")) { try NetworkRange(parsing: "192.0.2.1-300") }
        #expect(throws: NetworkRangeError.invalid("2001:db8::1")) { try NetworkRange(parsing: "2001:db8::1") }
    }

    @Test func refusesMoreThanASlash22() throws {
        #expect(try NetworkRange(parsing: "198.51.100.0/22").hosts.count == 1022)
        #expect(throws: NetworkRangeError.tooLarge(2048)) { try NetworkRange(parsing: "198.51.100.0/21") }
        #expect(throws: NetworkRangeError.tooLarge(16_777_216)) { try NetworkRange(parsing: "10.0.0.0/8") }
        #expect(throws: NetworkRangeError.tooLarge(1025)) { try NetworkRange(parsing: "198.51.100.0-198.51.104.0") }
        // Several parts count together.
        #expect(throws: NetworkRangeError.tooLarge(1276)) { try NetworkRange(parsing: "198.51.100.0/22 192.0.2.0/24") }
        let message = NetworkRangeError.tooLarge(2048).errorDescription ?? ""
        #expect(message.contains("2048") && message.contains("1024") && message.contains("/22"))
    }

    @Test func suggestsThePhonesNetworkCappedToASlash24() {
        #expect(NetworkRange.suggested(address: "192.0.2.57", netmask: "255.255.255.0") == "192.0.2.0/24")
        #expect(NetworkRange.suggested(address: "198.51.100.9", netmask: "255.255.252.0") == "198.51.100.0/22")
        #expect(NetworkRange.suggested(address: "198.51.101.9", netmask: "255.255.0.0") == "198.51.101.0/24")
        #expect(NetworkRange.suggested(address: "192.0.2.57", netmask: "255.0.255.0") == nil)
        #expect(NetworkRange.suggested(address: "nope", netmask: "255.255.255.0") == nil)
    }
}

@Suite struct ScanPortsTests {
    @Test func parsesListsAndDefaultsTo22() throws {
        #expect(try ScanPorts.parse("") == [22])
        #expect(try ScanPorts.parse("22, 2222 22,8022") == [22, 2222, 8022])
    }

    @Test func refusesBadPortsAndLongLists() {
        #expect(throws: NetworkRangeError.invalidPort("0")) { try ScanPorts.parse("0") }
        #expect(throws: NetworkRangeError.invalidPort("70000")) { try ScanPorts.parse("22 70000") }
        #expect(throws: NetworkRangeError.invalidPort("ssh")) { try ScanPorts.parse("ssh") }
        #expect(throws: NetworkRangeError.tooManyPorts(9)) { try ScanPorts.parse("1 2 3 4 5 6 7 8 9") }
    }
}
