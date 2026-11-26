import Foundation

/// Splits the agent channel's byte stream into messages: uint32 length, then that many bytes. Bytes may arrive in
/// any split; a length of 0 or above `maximumMessageSize` is a protocol error and the channel is closed.
public struct AgentFramer: Sendable {
    /// OpenSSH's own agent limit (AGENT_MAX_LEN, 256 KiB).
    public static let maximumMessageSize = 256 * 1024

    public enum FramingError: Error, Equatable, Sendable {
        case emptyMessage
        case tooLarge(Int)
    }

    private var pending: [UInt8] = []

    public init() {}

    /// Adds received bytes and returns every message now complete, in order.
    public mutating func append(_ bytes: some Sequence<UInt8>) throws(FramingError) -> [Data] {
        pending.append(contentsOf: bytes)
        var messages: [Data] = []
        var offset = 0
        while pending.count - offset >= 4 {
            let length = pending[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length > 0 else { throw .emptyMessage }
            guard length <= Self.maximumMessageSize else { throw .tooLarge(length) }
            guard pending.count - offset - 4 >= length else { break }
            messages.append(Data(pending[offset + 4..<offset + 4 + length]))
            offset += 4 + length
        }
        pending.removeFirst(offset)
        return messages
    }

    /// A payload with its length prefix.
    public static func frame(_ payload: Data) -> Data {
        var writer = SSHWireWriter()
        writer.string(payload)
        return writer.data
    }
}
