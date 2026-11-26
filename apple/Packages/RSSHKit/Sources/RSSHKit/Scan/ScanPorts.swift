import Foundation

/// The TCP ports a scan tries on each host, from "22, 2222 8022".
public enum ScanPorts {
    public static let maxCount = 8
    /// What a scan tries unless the user types other ports: SSH, RDP and VNC / Apple Screen Sharing, so screens are
    /// found too.
    public static let defaultText = "22 3389 5900"

    /// Each port once, in the order typed. A blank text means 22.
    public static func parse(_ text: String) throws(NetworkRangeError) -> [Int] {
        let items = text.split { $0 == "," || $0.isWhitespace }
        guard !items.isEmpty else { return [22] }
        var ports: [Int] = []
        for item in items {
            guard item.allSatisfy(\.isNumber), let port = Int(item), (1...65_535).contains(port) else {
                throw .invalidPort(String(item))
            }
            if !ports.contains(port) { ports.append(port) }
        }
        guard ports.count <= maxCount else { throw .tooManyPorts(ports.count) }
        return ports
    }
}
