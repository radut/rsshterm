import _CryptoExtras
import Crypto
import Foundation

/// A PuTTY `.ppk` file, versions 2 and 3 (PuTTY's sshpubk.c). Unencrypted keys of both versions and v2 keys with
/// `aes256-cbc` are read; v3 encryption derives its key with Argon2, which swift-crypto does not have.
struct PuTTYKey {
    let version: Int
    let keyType: String
    let encryption: String
    let comment: String
    let keyDerivation: String?
    let publicBlob: [UInt8]
    let privateBlob: [UInt8]
    let mac: [UInt8]

    static let marker = "PuTTY-User-Key-File-"

    var format: KeyFormat { .putty(version) }
    var isEncrypted: Bool { encryption != "none" }

    /// Reads the headers and the two base64 sections; line wrapping inside a section does not matter.
    static func parse(_ text: String) throws(KeyImportError) -> PuTTYKey {
        let lines = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var headers: [String: String] = [:]
        var sections: [String: String] = [:]
        var current: String?
        for line in lines.drop(while: { !$0.hasPrefix(marker) }) {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon])
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = name == "Public-Lines" || name == "Private-Lines" ? name : nil
            } else if let current {
                sections[current, default: ""] += line
            }
        }
        guard let first = headers.keys.first(where: { $0.hasPrefix(marker) }),
              let version = Int(first.dropFirst(marker.count)) else { throw .unrecognized }
        let format = KeyFormat.putty(version)
        guard version == 2 || version == 3 else { throw .unsupportedKeyDerivation(format, "the PuTTY v\(version) format") }
        guard let keyType = headers[first], let encryption = headers["Encryption"],
              let publicBlob = sections["Public-Lines"].flatMap({ PEMArmor.base64($0) }),
              let privateBlob = sections["Private-Lines"].flatMap({ PEMArmor.base64($0) }),
              let mac = headers["Private-MAC"].flatMap({ PEMArmor.hexBytes($0) }) else { throw .damaged(format) }
        return PuTTYKey(version: version, keyType: keyType, encryption: encryption, comment: headers["Comment"] ?? "",
                        keyDerivation: headers["Key-Derivation"], publicBlob: publicBlob, privateBlob: privateBlob,
                        mac: mac)
    }

    /// Decrypts and checks the MAC, then reads the key.
    func material(passphrase: String?) throws(KeyImportError) -> PrivateKeyMaterial {
        let phrase = isEncrypted ? (passphrase ?? "") : ""
        let secret = try decryptedPrivateBlob(passphrase: phrase)
        guard macMatches(privateBlob: secret, passphrase: phrase) else {
            throw isEncrypted ? .wrongPassphrase(format) : .damaged(format)
        }
        do {
            return try Self.material(keyType: keyType, publicBlob: publicBlob, privateBlob: secret)
        } catch DERKeyFailure.unsupportedKeyType(let type) {
            throw .unsupportedKeyType(format, type)
        } catch {
            throw .damaged(format)
        }
    }

    private func decryptedPrivateBlob(passphrase: String) throws(KeyImportError) -> [UInt8] {
        guard isEncrypted else { return privateBlob }
        guard version == 2 else { throw .unsupportedKeyDerivation(format, keyDerivation ?? "Argon2") }
        guard encryption == "aes256-cbc" else { throw .unsupportedCipher(format, encryption) }
        guard !passphrase.isEmpty else { throw .passphraseRequired(format) }
        guard !privateBlob.isEmpty, privateBlob.count % 16 == 0 else { throw .damaged(format) }
        let phrase = Array(passphrase.utf8)
        let key = Array(Insecure.SHA1.hash(data: [0, 0, 0, 0] + phrase)) + Array(Insecure.SHA1.hash(data: [0, 0, 0, 1] + phrase))
        do {
            return Array(try AES._CBC.decrypt(privateBlob, using: SymmetricKey(data: key.prefix(32)),
                                              iv: AES._CBC.IV(ivBytes: [UInt8](repeating: 0, count: 16)),
                                              noPadding: true))
        } catch {
            throw .damaged(format)
        }
    }

    /// v2: HMAC-SHA1 keyed with SHA1("putty-private-key-file-mac-key" ‖ passphrase). v3 unencrypted: HMAC-SHA256
    /// with an empty key. Both over the five fields as SSH strings.
    private func macMatches(privateBlob secret: [UInt8], passphrase: String) -> Bool {
        var data = SSHWireWriter()
        data.string(keyType)
        data.string(encryption)
        data.string(comment)
        data.string(Data(publicBlob))
        data.string(Data(secret))
        if version == 2 {
            let key = SymmetricKey(data: Insecure.SHA1.hash(data: Data("putty-private-key-file-mac-key".utf8)
                + Data(passphrase.utf8)))
            return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data.data, using: key)) == mac
        }
        return Array(HMAC<SHA256>.authenticationCode(for: data.data, using: SymmetricKey(data: Data()))) == mac
    }

    private static func material(keyType: String, publicBlob: [UInt8], privateBlob: [UInt8]) throws -> PrivateKeyMaterial {
        var pub = SSHWireReader(Data(publicBlob))
        var priv = SSHWireReader(Data(privateBlob))
        guard try pub.text() == keyType else { throw DERKeyFailure.malformed }
        if keyType == PrivateKeyMaterial.rsaType {
            let e = try pub.mpint(), n = try pub.mpint()
            let d = try priv.mpint(), p = try priv.mpint(), q = try priv.mpint(), iqmp = try priv.mpint()
            return .rsa(RSAKeyFields(n: n, e: e, d: d, p: p, q: q, iqmp: iqmp))
        }
        if keyType == SSHPublicKey.ed25519Type {
            let publicKey = Array(try pub.string())
            guard let key = PrivateKeyMaterial.checkedEd25519(seed: Array(try priv.string()), publicKey: publicKey) else {
                throw DERKeyFailure.malformed
            }
            return key
        }
        if let curve = ECCurve(keyType: keyType) {
            guard try pub.text() == curve.rawValue else { throw DERKeyFailure.malformed }
            let point = Array(try pub.string())
            guard let key = PrivateKeyMaterial.checkedECDSA(curve, scalar: try priv.mpint(), point: point) else {
                throw DERKeyFailure.malformed
            }
            return key
        }
        throw DERKeyFailure.unsupportedKeyType(keyType == "ssh-dss" ? "DSA" : keyType)
    }
}
