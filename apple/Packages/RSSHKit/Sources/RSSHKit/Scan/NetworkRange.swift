import Foundation

/// Why a scan range was refused. Messages are shown to the user as they are.
public enum NetworkRangeError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case invalid(String)
    case tooLarge(Int)
    case invalidPort(String)
    case tooManyPorts(Int)

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a range, for example 192.0.2.0/24."
        case .invalid(let part): "\"\(part)\" is not an IPv4 address, range or CIDR block."
        case .tooLarge(let count):
            "That is \(count) addresses; a scan covers at most \(NetworkRange.maxHosts) (a /22). Narrow the range."
        case .invalidPort(let text): "\"\(text)\" is not a port (1 to 65535)."
        case .tooManyPorts(let count): "That is \(count) ports; a scan tries at most \(ScanPorts.maxCount)."
        }
    }
}

/// The IPv4 hosts to scan, parsed from what the user typed: CIDR blocks ("192.0.2.0/24"), ranges ("192.0.2.10-50",
/// "192.0.2.10-192.0.2.60"), single addresses, any number of them separated by commas or spaces. A bare network address
/// (last part 0, "192.0.2.0") means its whole /24, .1 to .254.
public struct NetworkRange: Equatable, Sendable {
    public static let maxHosts = 1024

    /// Every host once, in the order typed.
    public let hosts: [IPv4]

    public init(parsing text: String) throws(NetworkRangeError) {
        let items = text.split { $0 == "," || $0.isWhitespace }
        guard !items.isEmpty else { throw .empty }
        var spans: [ClosedRange<UInt32>] = []
        var total = 0
        for item in items {
            let span = try Self.span(of: item)
            total += Int(span.upperBound - span.lowerBound) + 1
            guard total <= Self.maxHosts else { throw .tooLarge(total) }
            spans.append(span)
        }
        var seen = Set<UInt32>()
        hosts = spans.flatMap { $0 }.filter { seen.insert($0).inserted }.map(IPv4.init)
    }

    private static func span(of item: Substring) throws(NetworkRangeError) -> ClosedRange<UInt32> {
        if let slash = item.firstIndex(of: "/") { return try cidr(item, slash: slash) }
        if let dash = item.firstIndex(of: "-") { return try range(item, dash: dash) }
        guard let address = IPv4(item) else { throw .invalid(String(item)) }
        if address.value & 0xFF == 0 { return (address.value + 1)...(address.value + 254) }
        return address.value...address.value
    }

    /// Network and broadcast addresses are left out, except in /31 and /32.
    private static func cidr(_ item: Substring, slash: Substring.Index) throws(NetworkRangeError) -> ClosedRange<UInt32> {
        let bits = item[item.index(after: slash)...]
        guard let base = IPv4(item[..<slash]), bits.allSatisfy(\.isNumber), let prefix = Int(bits), (0...32).contains(prefix)
        else { throw .invalid(String(item)) }
        let mask = IPv4.mask(prefix: prefix)
        let first = base.value & mask, last = first | ~mask
        let size = Int(last - first) + 1
        guard size <= maxHosts + 2 else { throw .tooLarge(size) }
        return prefix >= 31 ? first...last : (first + 1)...(last - 1)
    }

    private static func range(_ item: Substring, dash: Substring.Index) throws(NetworkRangeError) -> ClosedRange<UInt32> {
        let tail = item[item.index(after: dash)...]
        guard let start = IPv4(item[..<dash]) else { throw .invalid(String(item)) }
        let end: UInt32
        if let full = IPv4(tail) {
            end = full.value
        } else if tail.allSatisfy(\.isNumber), let octet = UInt32(tail), octet <= 255 {
            end = start.value & 0xFFFF_FF00 | octet
        } else {
            throw .invalid(String(item))
        }
        guard end >= start.value else { throw .invalid(String(item)) }
        let size = Int(end - start.value) + 1
        guard size <= maxHosts else { throw .tooLarge(size) }
        return start.value...end
    }

    /// The range to offer for the phone's own network: its CIDR block, or the /24 around it when the network is
    /// larger than a scan may be. nil for a malformed address or mask.
    public static func suggested(address: String, netmask: String) -> String? {
        guard let ip = IPv4(address), let mask = IPv4(netmask), let prefix = IPv4.prefix(ofMask: mask) else { return nil }
        let used = prefix >= 22 ? prefix : 24
        let network = IPv4(ip.value & IPv4.mask(prefix: used))
        return "\(network)/\(used)"
    }
}
