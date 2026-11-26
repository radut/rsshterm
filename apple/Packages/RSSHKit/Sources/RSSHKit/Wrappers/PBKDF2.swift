import Crypto
import Foundation

/// PBKDF2-HMAC-SHA256 (RFC 8018) for one 32-byte block, on swift-crypto's HMAC, so no second crypto framework is
/// bundled with the app.
enum PBKDF2 {
    static func sha256(password: Data, salt: Data, rounds: Int) -> Data {
        // Keyed once; each round copies the keyed state instead of re-keying.
        let keyed = HMAC<SHA256>(key: SymmetricKey(data: password))
        var mac = keyed
        mac.update(data: salt + [0, 0, 0, 1])
        var u = Data(mac.finalize())
        var result = [UInt8](u)
        for _ in 1..<max(rounds, 1) {
            var next = keyed
            next.update(data: u)
            u = Data(next.finalize())
            for (index, byte) in u.enumerated() { result[index] ^= byte }
        }
        return Data(result)
    }
}
