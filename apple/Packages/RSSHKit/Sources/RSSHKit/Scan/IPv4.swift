import Foundation

/// An IPv4 address as a number, so ranges can be counted and walked. Text form is dotted decimal.
public struct IPv4: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var value: UInt32

    public init(_ value: UInt32) { self.value = value }

    /// Four decimal parts 0...255 ("192.0.2.1"); nil for anything else, host names included.
    public init?(_ text: some StringProtocol) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            value = value << 8 | octet
        }
        self.value = value
    }

    public var description: String {
        [24, 16, 8, 0].map { String(value >> UInt32($0) & 0xFF) }.joined(separator: ".")
    }

    public static func < (lhs: IPv4, rhs: IPv4) -> Bool { lhs.value < rhs.value }

    /// The mask of a prefix length (24 -> 255.255.255.0).
    static func mask(prefix: Int) -> UInt32 {
        prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
    }

    /// The prefix length of a contiguous netmask (255.255.255.0 -> 24); nil when the mask has holes.
    static func prefix(ofMask mask: IPv4) -> Int? {
        let ones = mask.value.nonzeroBitCount
        return mask.value == Self.mask(prefix: ones) ? ones : nil
    }
}
