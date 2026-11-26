import _CryptoExtras
import Crypto
import Foundation

/// Why an encrypted PEM body could not be opened.
enum PEMDecryptionFailure: Error, Equatable {
    /// Padding or structure is wrong after decryption: almost always a wrong passphrase.
    case wrongPassphrase
    case unsupportedCipher(String)
    case malformed
}

/// The two ways PEM private keys are protected by a passphrase: OpenSSL's legacy `Proc-Type: 4,ENCRYPTED` headers
/// (key = EVP_BytesToKey with MD5, one round) and PKCS#8 `ENCRYPTED PRIVATE KEY` with PBES2 (RFC 8018: PBKDF2 with
/// HMAC-SHA1 or HMAC-SHA256, then AES-CBC). DES-based ciphers are refused: swift-crypto has no DES.
enum PEMDecryption {
    /// A PBKDF2 iteration count beyond this is a hostile or broken file, not a real key.
    static let maxIterations = 10_000_000

    static func legacy(_ body: [UInt8], cipher: String, iv: [UInt8], passphrase: String) throws(PEMDecryptionFailure)
        -> [UInt8] {
        let keyLength: Int
        switch cipher {
        case "AES-128-CBC": keyLength = 16
        case "AES-192-CBC": keyLength = 24
        case "AES-256-CBC": keyLength = 32
        case "": throw .malformed
        default: throw .unsupportedCipher(cipher)
        }
        guard iv.count == 16 else { throw .malformed }
        let key = evpBytesToKey(password: Array(passphrase.utf8), salt: Array(iv.prefix(8)), length: keyLength)
        return try aesCBC(body, key: key, iv: iv)
    }

    /// Opens an EncryptedPrivateKeyInfo and returns the PrivateKeyInfo DER inside.
    static func pbes2(_ der: [UInt8], passphrase: String) throws(PEMDecryptionFailure) -> [UInt8] {
        let parameters: PBES2Parameters
        let encrypted: [UInt8]
        do {
            var outer = DERReader(der)
            var info = try outer.nested()
            var algorithm = try info.nested()
            let scheme = try algorithm.objectIdentifier()
            guard scheme == OID.pbes2 else { throw PEMDecryptionFailure.unsupportedCipher(Self.schemeName(scheme)) }
            parameters = try PBES2Parameters(try algorithm.nested())
            encrypted = try info.octetString()
        } catch let failure as PEMDecryptionFailure {
            throw failure
        } catch {
            throw .malformed
        }
        guard parameters.iterations > 0, parameters.iterations <= maxIterations else { throw .malformed }
        let derived: SymmetricKey
        do {
            derived = try KDF.Insecure.PBKDF2.deriveKey(
                from: Array(passphrase.utf8), salt: parameters.salt, using: parameters.prf,
                outputByteCount: parameters.keyLength, unsafeUncheckedRounds: parameters.iterations)
        } catch {
            throw .malformed
        }
        return try aesCBC(encrypted, key: derived.withUnsafeBytes { Array($0) }, iv: parameters.iv)
    }

    /// OpenSSL's EVP_BytesToKey(MD5, count 1): D₁ = MD5(pass ‖ salt), Dᵢ = MD5(Dᵢ₋₁ ‖ pass ‖ salt).
    static func evpBytesToKey(password: [UInt8], salt: [UInt8], length: Int) -> [UInt8] {
        var key: [UInt8] = []
        var previous: [UInt8] = []
        while key.count < length {
            previous = Array(Insecure.MD5.hash(data: previous + password + salt))
            key += previous
        }
        return Array(key.prefix(length))
    }

    private static func aesCBC(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) throws(PEMDecryptionFailure)
        -> [UInt8] {
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { throw .malformed }
        do {
            let vector = try AES._CBC.IV(ivBytes: iv)
            return Array(try AES._CBC.decrypt(ciphertext, using: SymmetricKey(data: key), iv: vector))
        } catch {
            throw .wrongPassphrase
        }
    }

    private static func schemeName(_ oid: String) -> String {
        oid.hasPrefix("1.2.840.113549.1.5.") || oid.hasPrefix("1.2.840.113549.1.12.1.") ? "PBES1 (\(oid))" : oid
    }
}

/// PBES2-params: the PBKDF2 salt, rounds and PRF, and the AES-CBC key length and IV.
private struct PBES2Parameters {
    let salt: [UInt8]
    let iterations: Int
    let keyLength: Int
    let prf: KDF.Insecure.PBKDF2.HashFunction
    let iv: [UInt8]

    init(_ reader: DERReader) throws(PEMDecryptionFailure) {
        var reader = reader
        do {
            var kdf = try reader.nested()
            guard try kdf.objectIdentifier() == OID.pbkdf2 else { throw PEMDecryptionFailure.unsupportedCipher("PBES2 KDF") }
            var kdfParameters = try kdf.nested()
            salt = try kdfParameters.octetString()
            iterations = try kdfParameters.smallInteger()
            let declaredLength = kdfParameters.nextTag == DERReader.Tag.integer.rawValue
                ? try kdfParameters.smallInteger() : nil
            prf = kdfParameters.isAtEnd ? .insecureSHA1 : try Self.prf(try kdfParameters.nested())
            var scheme = try reader.nested()
            let cipher = try scheme.objectIdentifier()
            keyLength = try Self.keyLength(cipher)
            guard declaredLength == nil || declaredLength == keyLength else { throw PEMDecryptionFailure.malformed }
            iv = try scheme.octetString()
            guard iv.count == 16 else { throw PEMDecryptionFailure.malformed }
        } catch let failure as PEMDecryptionFailure {
            throw failure
        } catch {
            throw .malformed
        }
    }

    private static func prf(_ identifier: DERReader) throws(PEMDecryptionFailure) -> KDF.Insecure.PBKDF2.HashFunction {
        var identifier = identifier
        guard let oid = try? identifier.objectIdentifier() else { throw .malformed }
        switch oid {
        case OID.hmacWithSHA1: return .insecureSHA1
        case OID.hmacWithSHA256: return .sha256
        default: throw .unsupportedCipher("PBKDF2 PRF \(oid)")
        }
    }

    private static func keyLength(_ cipher: String) throws(PEMDecryptionFailure) -> Int {
        switch cipher {
        case OID.aes128CBC: 16
        case OID.aes192CBC: 24
        case OID.aes256CBC: 32
        default: throw .unsupportedCipher(OID.name(cipher))
        }
    }
}
