import Crypto
import Foundation

/// Proof Key for Code Exchange (RFC 7636), S256: the code from the redirect is useless without the verifier, which
/// never leaves this process.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public init(verifier: String) {
        self.verifier = verifier
    }

    /// 32 random bytes as base64url: a 43-character verifier.
    public static func generate() -> PKCE { PKCE(verifier: randomToken(bytes: 32)) }

    static func randomToken(bytes: Int) -> String {
        base64URL(SymmetricKey(size: SymmetricKeySize(bitCount: bytes * 8)).withUnsafeBytes { Data($0) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
