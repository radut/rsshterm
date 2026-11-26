import Foundation

/// What can be read from any OpenSSH private key without decrypting it.
public struct OpenSSHKeyInfo: Equatable, Sendable {
    public let keyType: String
    public let publicKeyBlob: Data
    public let isEncrypted: Bool
    /// The comment sits inside the private (possibly encrypted) part, so it is nil for an encrypted key.
    public let comment: String?

    public var publicLine: String { SSHPublicKey.line(type: keyType, blob: publicKeyBlob, comment: comment) }
}

/// The `openssh-key-v1` private key format (PROTOCOL.key in OpenSSH): reads any key's public part, reads and writes
/// unencrypted ed25519, RSA and ECDSA keys.
public enum OpenSSHPrivateKey {
    static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let endMarker = "-----END OPENSSH PRIVATE KEY-----"
    static let magic = Data("openssh-key-v1\0".utf8)
    static let lineWidth = 70
    static let blockSize = 8

    /// The PEM text of `key`, unencrypted, exactly as `ssh-keygen` writes it. `checkInt` is random by default; a
    /// fixed one gives a reproducible file.
    public static func encode(_ key: Ed25519KeyPair, checkInt: UInt32 = .random(in: .min ... .max)) -> String {
        encode(.ed25519(seed: Array(key.seed), publicKey: Array(key.publicKey)), comment: key.comment, checkInt: checkInt)
    }

    /// The PEM text of any key read by `KeyImport`, unencrypted, as `ssh-keygen` writes it.
    static func encode(_ key: PrivateKeyMaterial, comment: String,
                       checkInt: UInt32 = .random(in: .min ... .max)) -> String {
        var body = SSHWireWriter()
        body.raw(magic)
        body.string("none")          // cipher
        body.string("none")          // kdf
        body.string(Data())          // kdf options
        body.uint32(1)               // number of keys
        body.string(key.publicBlob)
        body.string(privateSection(key, comment: comment, checkInt: checkInt))
        return armor(body.data)
    }

    /// Reads an unencrypted ed25519 key; throws a user-readable error for anything else.
    public static func decodeEd25519(_ pem: String) throws(OpenSSHKeyError) -> Ed25519KeyPair {
        let (key, comment) = try decode(pem)
        guard case .ed25519(let seed, _) = key else { throw .unsupportedKeyType(key.keyType) }
        return try Ed25519KeyPair(seed: Data(seed), comment: comment)
    }

    /// The curve and private scalar of an unencrypted ECDSA key, for logging in with it.
    public static func decodeECDSA(_ pem: String) throws(OpenSSHKeyError) -> (curve: ECCurve, scalar: Data) {
        let (key, _) = try decode(pem)
        guard case .ecdsa(let curve, let scalar, _) = key else { throw .unsupportedKeyType(key.keyType) }
        return (curve, Data(scalar))
    }

    /// The key and comment of any unencrypted key; its public part must match the private one.
    static func decode(_ pem: String) throws(OpenSSHKeyError) -> (key: PrivateKeyMaterial, comment: String) {
        let parts = try parse(pem)
        guard !parts.info.isEncrypted else { throw .encrypted }
        return try decodeSection(parts.privateSection, info: parts.info)
    }

    /// The key and comment of an encrypted key, from its private section decrypted elsewhere (`decrypt` gets the
    /// armored key and returns the section; the app hands it to Citadel's bcrypt + AES-CTR).
    static func decode(_ pem: String, decrypt: (String) throws -> Data) throws(OpenSSHKeyError)
        -> (key: PrivateKeyMaterial, comment: String) {
        let parts = try parse(pem)
        guard parts.info.isEncrypted else { return try decodeSection(parts.privateSection, info: parts.info) }
        let section: Data
        do { section = try decrypt(pem) } catch { throw .checkMismatch }
        return try decodeSection(section, info: parts.info)
    }

    /// Check numbers, key type, fields and comment of a plain private section; the public part must match `info`.
    private static func decodeSection(_ section: Data, info: OpenSSHKeyInfo) throws(OpenSSHKeyError)
        -> (key: PrivateKeyMaterial, comment: String) {
        var reader = SSHWireReader(section)
        guard try reader.uint32() == reader.uint32() else { throw .checkMismatch }
        guard try reader.text() == info.keyType else { throw .malformed }
        let key = try PrivateKeyMaterial.readPrivateFields(keyType: info.keyType, from: &reader)
        let comment = try reader.text()
        guard key.publicBlob == info.publicKeyBlob else { throw .checkMismatch }
        return (key, comment)
    }

    /// The same key re-armored as `ssh-keygen` writes it (LF line ends, 70 columns), whatever the paste did to it.
    static func normalized(_ pem: String) throws(OpenSSHKeyError) -> String {
        _ = try parse(pem)
        return armor(try unarmor(pem))
    }

    /// The key type, public key and (when unencrypted) comment of any OpenSSH private key.
    public static func inspect(_ pem: String) throws(OpenSSHKeyError) -> OpenSSHKeyInfo {
        try parse(pem).info
    }

    // MARK: - Private

    private struct Parts {
        let info: OpenSSHKeyInfo
        let privateSection: Data
    }

    private static func parse(_ pem: String) throws(OpenSSHKeyError) -> Parts {
        var reader = SSHWireReader(try unarmor(pem))
        guard Data(try reader.take(magic.count)) == magic else { throw .notOpenSSHKey }
        let cipher = try reader.text()
        _ = try reader.text()     // kdf name
        _ = try reader.string()   // kdf options
        guard try reader.uint32() == 1 else { throw .malformed }
        let blob = try reader.string()
        let privateSection = try reader.string()
        var blobReader = SSHWireReader(blob)
        let keyType = try blobReader.text()
        let encrypted = cipher != "none"
        let comment = encrypted ? nil : try commentOf(privateSection)
        let info = OpenSSHKeyInfo(keyType: keyType, publicKeyBlob: blob, isEncrypted: encrypted, comment: comment)
        return Parts(info: info, privateSection: privateSection)
    }

    /// After the two check numbers every field of every key type is a string, the comment is the last one, then
    /// padding 1, 2, 3, … up to the block size. Padding starts at 1 and a string length at 0, so they never mix up.
    private static func commentOf(_ section: Data) throws(OpenSSHKeyError) -> String {
        var reader = SSHWireReader(section)
        guard try reader.uint32() == reader.uint32() else { throw .checkMismatch }
        var last: Data?
        while !isPadding(reader.remaining) {
            last = try reader.string()
        }
        guard let last, let comment = String(data: last, encoding: .utf8) else { throw .malformed }
        return comment
    }

    private static func isPadding(_ bytes: Data) -> Bool {
        bytes.count < blockSize && bytes.elementsEqual((0..<bytes.count).map { UInt8($0 + 1) })
    }

    private static func privateSection(_ key: PrivateKeyMaterial, comment: String, checkInt: UInt32) -> Data {
        var section = SSHWireWriter()
        section.uint32(checkInt)
        section.uint32(checkInt)
        section.string(key.keyType)
        key.writePrivateFields(to: &section)
        section.string(comment)
        let padding = (blockSize - section.data.count % blockSize) % blockSize
        section.raw(Data((0..<padding).map { UInt8($0 + 1) }))
        return section.data
    }

    private static func armor(_ data: Data) -> String {
        let base64 = Array(data.base64EncodedString())
        let lines = stride(from: 0, to: base64.count, by: lineWidth).map {
            String(base64[$0..<min($0 + lineWidth, base64.count)])
        }
        return ([beginMarker] + lines + [endMarker]).joined(separator: "\n") + "\n"
    }

    static func unarmor(_ pem: String) throws(OpenSSHKeyError) -> Data {
        let text = pem.replacingOccurrences(of: "\r", with: "")
        guard let begin = text.range(of: beginMarker),
              let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex) else { throw .notOpenSSHKey }
        let base64 = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)), !data.isEmpty else { throw .malformed }
        return data
    }
}
