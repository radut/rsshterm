import Foundation

/// Just enough DER (X.690) to read private key containers: SEQUENCE, INTEGER, OCTET/BIT STRING, OBJECT IDENTIFIER
/// and context tags. Every read past the end, or of an unexpected tag, throws instead of trapping.
struct DERReader {
    enum Tag: UInt8 {
        case integer = 0x02, bitString = 0x03, octetString = 0x04, null = 0x05, objectIdentifier = 0x06
        case sequence = 0x30
    }

    struct Failure: Error {}

    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = Array(data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset == bytes.count }

    /// The tag of the next element, without reading it.
    var nextTag: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    /// The contents of the next element, which must carry `tag`.
    mutating func read(_ tag: UInt8) throws(Failure) -> [UInt8] {
        guard nextTag == tag else { throw Failure() }
        offset += 1
        let length = try readLength()
        guard length <= bytes.count - offset else { throw Failure() }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }

    mutating func read(_ tag: Tag) throws(Failure) -> [UInt8] { try read(tag.rawValue) }

    /// A constructed element (SEQUENCE or a context tag) as its own reader.
    mutating func nested(_ tag: UInt8 = Tag.sequence.rawValue) throws(Failure) -> DERReader {
        DERReader(try read(tag))
    }

    /// A non-negative INTEGER as its big-endian magnitude, without the sign byte (zero is empty).
    mutating func unsignedInteger() throws(Failure) -> [UInt8] {
        let content = try read(.integer)
        guard let first = content.first, first & 0x80 == 0 else { throw Failure() }
        return Array(content.drop { $0 == 0 })
    }

    /// A small INTEGER such as a version number or an iteration count.
    mutating func smallInteger() throws(Failure) -> Int {
        let magnitude = try unsignedInteger()
        guard magnitude.count <= 4 else { throw Failure() }
        return magnitude.reduce(0) { $0 << 8 | Int($1) }
    }

    mutating func objectIdentifier() throws(Failure) -> String { try Self.oidString(try read(.objectIdentifier)) }

    mutating func octetString() throws(Failure) -> [UInt8] { try read(.octetString) }

    /// A BIT STRING with no unused bits (keys and points always are).
    mutating func bitString() throws(Failure) -> [UInt8] {
        let content = try read(.bitString)
        guard content.first == 0 else { throw Failure() }
        return Array(content.dropFirst())
    }

    private mutating func readLength() throws(Failure) -> Int {
        guard offset < bytes.count else { throw Failure() }
        let first = bytes[offset]
        offset += 1
        guard first & 0x80 != 0 else { return Int(first) }
        let count = Int(first & 0x7f)
        guard (1...4).contains(count), count <= bytes.count - offset else { throw Failure() }
        defer { offset += count }
        return bytes[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
    }

    static func oidString(_ content: [UInt8]) throws(Failure) -> String {
        guard let first = content.first else { throw Failure() }
        var arcs = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in content.dropFirst() {
            guard value < Int.max >> 8 else { throw Failure() }
            value = value << 7 | Int(byte & 0x7f)
            if byte & 0x80 == 0 {
                arcs.append(value)
                value = 0
            }
        }
        return arcs.map(String.init).joined(separator: ".")
    }
}

/// The object identifiers of the key and cipher algorithms an import can meet.
enum OID {
    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let ed25519 = "1.3.101.112"
    static let x25519 = "1.3.101.110"
    static let ed448 = "1.3.101.113"
    static let dsa = "1.2.840.10040.4.1"
    static let prime256v1 = "1.2.840.10045.3.1.7"
    static let secp384r1 = "1.3.132.0.34"
    static let secp521r1 = "1.3.132.0.35"
    static let pbes2 = "1.2.840.113549.1.5.13"
    static let pbkdf2 = "1.2.840.113549.1.5.12"
    static let hmacWithSHA1 = "1.2.840.113549.2.7"
    static let hmacWithSHA256 = "1.2.840.113549.2.9"
    static let aes128CBC = "2.16.840.1.101.3.4.1.2"
    static let aes192CBC = "2.16.840.1.101.3.4.1.22"
    static let aes256CBC = "2.16.840.1.101.3.4.1.42"
    static let desEDE3CBC = "1.2.840.113549.3.7"

    /// A readable name for an algorithm an error message mentions.
    static func name(_ oid: String) -> String {
        switch oid {
        case x25519: "X25519"
        case ed448: "Ed448"
        case dsa: "DSA"
        case desEDE3CBC: "DES-EDE3-CBC"
        default: oid
        }
    }
}
