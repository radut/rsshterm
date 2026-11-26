import Foundation

/// Why a DER key structure could not become key material.
enum DERKeyFailure: Error, Equatable {
    case malformed
    case unsupportedKeyType(String)
}

/// The DER private key structures: PKCS#1 RSAPrivateKey (RFC 8017 A.1.2), SEC1 ECPrivateKey (RFC 5915) and
/// PKCS#8 PrivateKeyInfo / OneAsymmetricKey (RFC 5208, RFC 5958, RFC 8410 for Ed25519).
enum DERPrivateKeys {
    static func pkcs1RSA(_ der: [UInt8]) throws(DERKeyFailure) -> PrivateKeyMaterial {
        do {
            var outer = DERReader(der)
            var key = try outer.nested()
            guard try key.smallInteger() == 0 else { throw DERKeyFailure.unsupportedKeyType("multi-prime RSA") }
            let n = try key.unsignedInteger(), e = try key.unsignedInteger(), d = try key.unsignedInteger()
            let p = try key.unsignedInteger(), q = try key.unsignedInteger()
            _ = try key.unsignedInteger()   // d mod (p-1)
            _ = try key.unsignedInteger()   // d mod (q-1)
            let iqmp = try key.unsignedInteger()
            guard [n, e, d, p, q, iqmp].allSatisfy({ !$0.isEmpty }) else { throw DERKeyFailure.malformed }
            return .rsa(RSAKeyFields(n: n, e: e, d: d, p: p, q: q, iqmp: iqmp))
        } catch let failure as DERKeyFailure {
            throw failure
        } catch {
            throw .malformed
        }
    }

    /// `curve` comes from the PKCS#8 algorithm when the key sits inside one; a bare SEC1 key names its own.
    static func sec1EC(_ der: [UInt8], curve outerCurve: ECCurve? = nil) throws(DERKeyFailure) -> PrivateKeyMaterial {
        let parsed: (scalar: [UInt8], curveOID: String?, point: [UInt8]?)
        do {
            var outer = DERReader(der)
            var key = try outer.nested()
            guard try key.smallInteger() == 1 else { throw DERKeyFailure.malformed }
            let scalar = try key.octetString()
            var curveOID: String?
            var point: [UInt8]?
            if key.nextTag == 0xa0 {
                var parameters = try key.nested(0xa0)
                curveOID = try parameters.objectIdentifier()
            }
            if key.nextTag == 0xa1 {
                var publicKey = try key.nested(0xa1)
                point = try publicKey.bitString()
            }
            parsed = (scalar, curveOID, point)
        } catch let failure as DERKeyFailure {
            throw failure
        } catch {
            throw .malformed
        }
        let curve: ECCurve
        if let oid = parsed.curveOID {
            guard let named = ECCurve(oid: oid) else { throw .unsupportedKeyType("EC curve \(oid)") }
            guard outerCurve == nil || outerCurve == named else { throw .malformed }
            curve = named
        } else {
            guard let outerCurve else { throw .malformed }
            curve = outerCurve
        }
        guard let material = PrivateKeyMaterial.checkedECDSA(curve, scalar: parsed.scalar, point: parsed.point) else {
            throw .malformed
        }
        return material
    }

    static func pkcs8(_ der: [UInt8]) throws(DERKeyFailure) -> PrivateKeyMaterial {
        let algorithm: String, parameter: String?, privateKey: [UInt8]
        do {
            var outer = DERReader(der)
            var info = try outer.nested()
            guard try info.smallInteger() <= 1 else { throw DERKeyFailure.malformed }
            var identifier = try info.nested()
            algorithm = try identifier.objectIdentifier()
            parameter = identifier.nextTag == DERReader.Tag.objectIdentifier.rawValue
                ? try identifier.objectIdentifier() : nil
            privateKey = try info.octetString()
        } catch let failure as DERKeyFailure {
            throw failure
        } catch {
            throw .malformed
        }
        switch algorithm {
        case OID.rsaEncryption:
            return try pkcs1RSA(privateKey)
        case OID.ecPublicKey:
            guard let oid = parameter else { throw .malformed }
            guard let curve = ECCurve(oid: oid) else { throw .unsupportedKeyType("EC curve \(oid)") }
            return try sec1EC(privateKey, curve: curve)
        case OID.ed25519:
            var inner = DERReader(privateKey)
            guard let seed = try? inner.octetString(), inner.isAtEnd,
                  let material = PrivateKeyMaterial.checkedEd25519(seed: seed, publicKey: nil) else { throw .malformed }
            return material
        default:
            throw .unsupportedKeyType(OID.name(algorithm))
        }
    }
}
