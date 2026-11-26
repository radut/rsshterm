import Crypto
import Foundation

/// The NIST curves OpenSSH names `ecdsa-sha2-nistp256/384/521`.
public enum ECCurve: String, CaseIterable, Equatable, Sendable {
    case p256 = "nistp256", p384 = "nistp384", p521 = "nistp521"

    public var keyType: String { "ecdsa-sha2-\(rawValue)" }

    /// The length of a private scalar, and of each coordinate of a point.
    var scalarSize: Int {
        switch self {
        case .p256: 32
        case .p384: 48
        case .p521: 66
        }
    }

    init?(oid: String) {
        switch oid {
        case OID.prime256v1: self = .p256
        case OID.secp384r1: self = .p384
        case OID.secp521r1: self = .p521
        default: return nil
        }
    }

    init?(keyType: String) {
        guard let curve = Self.allCases.first(where: { $0.keyType == keyType }) else { return nil }
        self = curve
    }

    /// The scalar left-padded to the curve's size; nil when it is longer.
    func paddedScalar(_ scalar: [UInt8]) -> [UInt8]? {
        let trimmed = Array(scalar.drop { $0 == 0 })
        guard trimmed.count <= scalarSize, !trimmed.isEmpty else { return nil }
        return [UInt8](repeating: 0, count: scalarSize - trimmed.count) + trimmed
    }

    /// The uncompressed public point (0x04 | x | y) of a private scalar; nil when the scalar is out of range.
    func publicPoint(scalar: [UInt8]) -> [UInt8]? {
        guard let padded = paddedScalar(scalar) else { return nil }
        return switch self {
        case .p256: (try? P256.Signing.PrivateKey(rawRepresentation: padded)).map { Array($0.publicKey.x963Representation) }
        case .p384: (try? P384.Signing.PrivateKey(rawRepresentation: padded)).map { Array($0.publicKey.x963Representation) }
        case .p521: (try? P521.Signing.PrivateKey(rawRepresentation: padded)).map { Array($0.publicKey.x963Representation) }
        }
    }
}

/// The numbers of an RSA private key, each a big-endian magnitude. `iqmp` is q⁻¹ mod p (PKCS#1's coefficient).
struct RSAKeyFields: Equatable, Sendable {
    let n, e, d, p, q, iqmp: [UInt8]
}

/// A private key read from any supported format, before it is written as an OpenSSH key.
enum PrivateKeyMaterial: Equatable, Sendable {
    case rsa(RSAKeyFields)
    case ecdsa(ECCurve, scalar: [UInt8], point: [UInt8])
    case ed25519(seed: [UInt8], publicKey: [UInt8])

    static let rsaType = "ssh-rsa"

    var keyType: String {
        switch self {
        case .rsa: Self.rsaType
        case .ecdsa(let curve, _, _): curve.keyType
        case .ed25519: SSHPublicKey.ed25519Type
        }
    }

    /// An ECDSA key from its scalar; the point is computed, and must match `point` when the file carries one.
    static func checkedECDSA(_ curve: ECCurve, scalar: [UInt8], point: [UInt8]?) -> PrivateKeyMaterial? {
        guard let padded = curve.paddedScalar(scalar), let computed = curve.publicPoint(scalar: padded) else { return nil }
        if let point, point != computed { return nil }
        return .ecdsa(curve, scalar: padded, point: computed)
    }

    /// An ed25519 key from its 32-byte seed; the public key is computed, and must match `publicKey` when given.
    static func checkedEd25519(seed: [UInt8], publicKey: [UInt8]?) -> PrivateKeyMaterial? {
        guard seed.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        let computed = Array(key.publicKey.rawRepresentation)
        if let publicKey, publicKey != computed { return nil }
        return .ed25519(seed: seed, publicKey: computed)
    }

    /// The SSH wire blob of the public key, as in `authorized_keys`.
    var publicBlob: Data {
        var writer = SSHWireWriter()
        writer.string(keyType)
        switch self {
        case .rsa(let key):
            writer.mpint(key.e)
            writer.mpint(key.n)
        case .ecdsa(let curve, _, let point):
            writer.string(curve.rawValue)
            writer.string(Data(point))
        case .ed25519(_, let publicKey):
            writer.string(Data(publicKey))
        }
        return writer.data
    }

    /// The key's fields in an OpenSSH private section, after the key type (PROTOCOL.key, sshkey_private_serialize).
    func writePrivateFields(to writer: inout SSHWireWriter) {
        switch self {
        case .rsa(let key):
            for field in [key.n, key.e, key.d, key.iqmp, key.p, key.q] { writer.mpint(field) }
        case .ecdsa(let curve, let scalar, let point):
            writer.string(curve.rawValue)
            writer.string(Data(point))
            writer.mpint(scalar)
        case .ed25519(let seed, let publicKey):
            writer.string(Data(publicKey))
            writer.string(Data(seed + publicKey))
        }
    }

    /// Reads the fields `writePrivateFields` writes, for a key of `keyType`.
    static func readPrivateFields(keyType: String, from reader: inout SSHWireReader) throws(OpenSSHKeyError) -> Self {
        if keyType == rsaType {
            let (n, e, d, iqmp, p, q) = (try reader.mpint(), try reader.mpint(), try reader.mpint(),
                                         try reader.mpint(), try reader.mpint(), try reader.mpint())
            return .rsa(RSAKeyFields(n: n, e: e, d: d, p: p, q: q, iqmp: iqmp))
        }
        if let curve = ECCurve(keyType: keyType) {
            guard try reader.text() == curve.rawValue else { throw .malformed }
            let point = Array(try reader.string())
            guard let key = checkedECDSA(curve, scalar: try reader.mpint(), point: point) else { throw .checkMismatch }
            return key
        }
        guard keyType == SSHPublicKey.ed25519Type else { throw .unsupportedKeyType(keyType) }
        let publicKey = Array(try reader.string())
        let secret = Array(try reader.string())
        guard secret.count == 64, publicKey.count == 32, Array(secret.suffix(32)) == publicKey else {
            throw .invalidKeyLength
        }
        guard let key = checkedEd25519(seed: Array(secret.prefix(32)), publicKey: publicKey) else { throw .checkMismatch }
        return key
    }
}
