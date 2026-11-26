import Crypto
import Foundation

/// An ed25519 key as OpenSSH stores it: the 32-byte seed (the private key), its public key and a comment.
public struct Ed25519KeyPair: Equatable, Sendable {
    public let seed: Data
    public let publicKey: Data
    public let comment: String

    /// Derives the public key from the seed, so the pair is always consistent.
    public init(seed: Data, comment: String) throws(OpenSSHKeyError) {
        guard seed.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { throw .invalidKeyLength }
        self.seed = seed
        self.publicKey = key.publicKey.rawRepresentation
        self.comment = comment
    }

    /// A new random key (CryptoKit's Curve25519 signing key).
    public static func generate(comment: String) -> Ed25519KeyPair {
        let key = Curve25519.Signing.PrivateKey()
        // A fresh key's raw representation is always 32 bytes, so this cannot fail.
        return try! Ed25519KeyPair(seed: key.rawRepresentation, comment: comment)
    }

    /// `ssh-ed25519 AAAA… comment`, ready for a server's `authorized_keys`.
    public var publicLine: String { SSHPublicKey.ed25519Line(publicKey: publicKey, comment: comment) }
}
