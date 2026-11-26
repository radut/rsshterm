import _CryptoExtras
import Crypto
import Foundation
import Testing
@testable import RSSHKit

/// Checks a converted key against what ssh-keygen or puttygen printed for the same key.
enum KeyImportCheck {
    /// `type base64` of a public line, without its comment.
    static func bare(_ line: String) -> String { line.split(separator: " ").prefix(2).joined(separator: " ") }

    static func publicLine(_ key: ImportedKey) -> String {
        SSHPublicKey.line(type: key.info.keyType, blob: key.info.publicKeyBlob, comment: nil)
    }

    /// The converted key byte for byte as `ssh-keygen -p` wrote the same key: same fields, comment and check number.
    static func matchesSSHKeygen(_ key: ImportedKey, openSSH: String) throws -> Bool {
        let theirs = try OpenSSHPrivateKey.decode(openSSH)
        let ours = try OpenSSHPrivateKey.decode(key.pem)
        let rewritten = OpenSSHPrivateKey.encode(ours.key, comment: theirs.comment, checkInt: try checkInt(openSSH))
        // The literals in the vector files end without the final newline ssh-keygen writes.
        return ours.key == theirs.key && rewritten == openSSH + "\n"
    }

    /// Signs with the converted private key and verifies with the public key the other tool printed.
    static func signsAndVerifies(_ key: ImportedKey, publicLine: String) throws -> Bool {
        let message = Data("rsshkit import round trip".utf8)
        let blob = try #require(Data(base64Encoded: String(publicLine.split(separator: " ")[1])))
        var reader = SSHWireReader(blob)
        _ = try reader.text()
        switch try OpenSSHPrivateKey.decode(key.pem).key {
        case .rsa(let fields):
            let e = try reader.mpint(), n = try reader.mpint()
            let signer = try _RSA.Signing.PrivateKey(n: fields.n, e: fields.e, d: fields.d, p: fields.p, q: fields.q)
            let signature = try signer.signature(for: SHA256.hash(data: message), padding: .insecurePKCS1v1_5)
            let verifier = try _RSA.Signing.PublicKey(n: n, e: e)
            return verifier.isValidSignature(signature, for: SHA256.hash(data: message), padding: .insecurePKCS1v1_5)
        case .ecdsa(let curve, let scalar, _):
            _ = try reader.text()
            let point = try reader.string()
            switch curve {
            case .p256:
                let signature = try P256.Signing.PrivateKey(rawRepresentation: scalar).signature(for: message)
                return try P256.Signing.PublicKey(x963Representation: point).isValidSignature(signature, for: message)
            case .p384:
                let signature = try P384.Signing.PrivateKey(rawRepresentation: scalar).signature(for: message)
                return try P384.Signing.PublicKey(x963Representation: point).isValidSignature(signature, for: message)
            case .p521:
                let signature = try P521.Signing.PrivateKey(rawRepresentation: scalar).signature(for: message)
                return try P521.Signing.PublicKey(x963Representation: point).isValidSignature(signature, for: message)
            }
        case .ed25519(let seed, _):
            let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
            return try Curve25519.Signing.PublicKey(rawRepresentation: try reader.string())
                .isValidSignature(signature, for: message)
        }
    }

    /// Converts, then checks the public line and a signature against `publicLine`.
    static func converts(_ text: String, passphrase: String? = nil, to publicLine: String,
                         format: KeyFormat) throws -> ImportedKey {
        let key = try KeyImport.convert(text, passphrase: passphrase, comment: "")
        #expect(key.format == format)
        #expect(key.passphrase == nil)
        #expect(Self.publicLine(key) == bare(publicLine))
        #expect(try signsAndVerifies(key, publicLine: publicLine))
        #expect(key.pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        #expect(try OpenSSHPrivateKey.inspect(key.pem).isEncrypted == false)
        return key
    }

    private static func checkInt(_ openSSH: String) throws -> UInt32 {
        let base64 = openSSH.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var reader = SSHWireReader(try #require(Data(base64Encoded: base64)))
        _ = try reader.take(15)
        _ = try reader.string(); _ = try reader.string(); _ = try reader.string(); _ = try reader.uint32()
        _ = try reader.string()
        var section = SSHWireReader(try reader.string())
        return try section.uint32()
    }

    /// Re-wraps the base64 lines of a PEM block to `width` columns.
    static func rewrapped(_ pem: String, width: Int) -> String {
        let lines = pem.split(separator: "\n").map(String.init)
        let body = lines.dropFirst().dropLast().filter { !$0.contains(":") }.joined()
        let headers = lines.dropFirst().dropLast().filter { $0.contains(":") }
        let chunks = stride(from: 0, to: body.count, by: width).map {
            String(Array(body)[$0..<min($0 + width, body.count)])
        }
        return ([lines[0]] + headers + chunks + [lines[lines.count - 1]]).joined(separator: "\n")
    }
}
