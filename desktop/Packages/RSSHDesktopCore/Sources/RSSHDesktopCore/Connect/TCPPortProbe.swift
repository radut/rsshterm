import Foundation
import RSSHKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The desktop's port probe for the network scan: a non-blocking TCP connect to an IPv4 address, then up to one
/// line of what the server sends first (an SSH banner), all within `timeout`. Runs on a global queue (blocking
/// poll), never on the cooperative pool.
public struct TCPPortProbe: PortProbe {
    public init() {}

    public func probe(host: String, port: Int, timeout: Duration) async -> ProbeOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.blockingProbe(host: host, port: port, timeout: timeout))
            }
        }
    }

    static func blockingProbe(host: String, port: Int, timeout: Duration) -> ProbeOutcome {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return .closed }
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return .closed }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(Self.seconds(timeout))

        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if started != 0 {
            guard errno == EINPROGRESS else { return errno == ECONNREFUSED ? .refused : .closed }
            // Darwin wakes a refused connect with POLLHUP alone (no POLLOUT): any wake-up ends the wait and
            // SO_ERROR says what happened.
            guard wait(fd, events: Int16(POLLOUT), until: deadline, orError: true) else { return .closed }
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
            if failure == ECONNREFUSED { return .refused }
            guard failure == 0 else { return .closed }
        }
        // Connected: read the first line the server sends, if it sends one in time.
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while line.count < 512, wait(fd, events: Int16(POLLIN), until: deadline) {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            line.append(contentsOf: buffer[0..<n])
            if line.contains(UInt8(ascii: "\n")) { break }
        }
        guard !line.isEmpty else { return .open(firstLine: nil) }
        let text = String(decoding: line, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return .open(firstLine: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when `events` (or, with `orError`, an error or hang-up) arrived before `deadline`.
    private static func wait(_ fd: Int32, events: Int16, until deadline: Date, orError: Bool = false) -> Bool {
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let wanted = orError ? events | Int16(POLLERR) | Int16(POLLHUP) : events
        return poll(&descriptor, 1, remaining) > 0 && descriptor.revents & wanted != 0
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// This computer's IPv4 subnets (getifaddrs), for the scan's suggested range.
public enum LocalSubnets {
    public struct Interface: Equatable, Sendable {
        public let name: String
        public let address: String
        public let netmask: String
    }

    /// Up, non-loopback IPv4 interfaces, in system order.
    public static func interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                  let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            out.append(Interface(name: String(cString: entry.ifa_name), address: text(addr), netmask: text(mask)))
        }
        return out
    }

    /// The first interface's range as the scan field shows it ("192.0.2.0/24" style), nil without one.
    public static func suggestedRange(_ interfaces: [Interface] = interfaces()) -> String? {
        for interface in interfaces {
            if let range = NetworkRange.suggested(address: interface.address, netmask: interface.netmask) { return range }
        }
        return nil
    }

    private static func text(_ address: UnsafeMutablePointer<sockaddr>) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
            var value = inet.pointee.sin_addr
            _ = inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN))
        }
        return String(cString: buffer)
    }
}
