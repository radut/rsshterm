import Foundation

/// Builds SSH wire-format bytes (RFC 4251 §5): big-endian uint32 and length-prefixed strings.
struct SSHWireWriter {
    private(set) var data = Data()

    mutating func uint32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
                                 UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    mutating func string(_ bytes: Data) {
        uint32(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func string(_ text: String) { string(Data(text.utf8)) }

    /// A non-negative mpint from its big-endian magnitude: no leading zeros, plus one when the top bit is set.
    mutating func mpint(_ magnitude: [UInt8]) {
        let trimmed = Array(magnitude.drop { $0 == 0 })
        let sign: [UInt8] = (trimmed.first ?? 0) & 0x80 != 0 ? [0] : []
        string(Data(sign + trimmed))
    }

    mutating func raw(_ bytes: Data) { data.append(bytes) }
}

/// Reads SSH wire-format bytes; every read past the end throws instead of trapping.
struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    var isAtEnd: Bool { offset == bytes.count }
    var remaining: Data { Data(bytes[offset...]) }

    mutating func uint32() throws(OpenSSHKeyError) -> UInt32 {
        let chunk = try take(4)
        return chunk.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() throws(OpenSSHKeyError) -> Data {
        let length = try uint32()
        return Data(try take(Int(length)))
    }

    mutating func text() throws(OpenSSHKeyError) -> String {
        guard let value = String(data: try string(), encoding: .utf8) else { throw .malformed }
        return value
    }

    /// A non-negative mpint as its big-endian magnitude, without leading zeros.
    mutating func mpint() throws(OpenSSHKeyError) -> [UInt8] {
        let bytes = Array(try string())
        guard bytes.first.map({ $0 & 0x80 == 0 }) ?? true else { throw .malformed }
        return Array(bytes.drop { $0 == 0 })
    }

    mutating func take(_ count: Int) throws(OpenSSHKeyError) -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.count - offset else { throw .malformed }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }
}
