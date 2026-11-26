import Crypto
import Foundation

/// OpenBSD's bcrypt_pbkdf: the key derivation of passphrase-protected OpenSSH private keys ("kdfname bcrypt").
/// SHA-512 of the password and of salt‖counter feed a Blowfish-based hash ("eksblowfish" with 64 rounds per call),
/// `rounds` times; output bytes are spread across the blocks, as the C code does.
public enum BcryptPBKDF {
    /// Throws `OpenSSHKeyError.malformed` for an empty password or salt, rounds < 1 or a length out of 1...1024.
    public static func derive(password: Data, salt: Data, rounds: Int, length: Int) throws(OpenSSHKeyError) -> Data {
        guard !password.isEmpty, !salt.isEmpty, rounds >= 1, (1...1024).contains(length), salt.count <= 1 << 20 else {
            throw .malformed
        }
        let blockSize = 32
        let stride = (length + blockSize - 1) / blockSize
        var amount = (length + stride - 1) / stride
        var key = [UInt8](repeating: 0, count: length)
        let sha2pass = Array(SHA512.hash(data: password))
        var remaining = length
        var count: UInt32 = 1
        let state = Blowfish()
        while remaining > 0 {
            var countSalt = salt
            countSalt.append(contentsOf: [UInt8(count >> 24), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)])
            var sha2salt = Array(SHA512.hash(data: countSalt))
            var tmp = state.bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
            var out = tmp
            for _ in 1..<rounds {
                sha2salt = Array(SHA512.hash(data: tmp))
                tmp = state.bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
                for i in 0..<blockSize { out[i] ^= tmp[i] }
            }
            amount = min(amount, remaining)
            var i = 0
            while i < amount {
                let dest = i * stride + Int(count - 1)
                if dest >= length { break }
                key[dest] = out[i]
                i += 1
            }
            remaining -= i
            count += 1
        }
        return Data(key)
    }
}

/// Blowfish as bcrypt uses it (OpenBSD blf.c): key schedule with salt (`expandState`), the plain key schedule
/// (`expand0State`) and ECB encryption of 32-bit word pairs. One instance, reset by `bcryptHash` each call.
private final class Blowfish {
    private var s = [UInt32](repeating: 0, count: 1024)
    private var p = [UInt32](repeating: 0, count: 18)

    /// "OxychromaticBlowfishSwatDynamite" encrypted 64 times under the state keyed by salt and password.
    func bcryptHash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        s = BlowfishTables.s
        p = BlowfishTables.p
        expandState(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            expand0State(key: sha2salt)
            expand0State(key: sha2pass)
        }
        let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)
        var j = 0
        var cdata = (0..<8).map { _ in Self.streamToWord(magic, &j) }
        for _ in 0..<64 {
            for k in Swift.stride(from: 0, to: 8, by: 2) {
                (cdata[k], cdata[k + 1]) = encipher(cdata[k], cdata[k + 1])
            }
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 { // little-endian, as bcrypt_hash writes it
            out[4 * i] = UInt8(cdata[i] & 0xff)
            out[4 * i + 1] = UInt8(cdata[i] >> 8 & 0xff)
            out[4 * i + 2] = UInt8(cdata[i] >> 16 & 0xff)
            out[4 * i + 3] = UInt8(cdata[i] >> 24)
        }
        return out
    }

    private static func streamToWord(_ data: [UInt8], _ j: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if j >= data.count { j = 0 }
            word = word << 8 | UInt32(data[j])
            j += 1
        }
        return word
    }

    @inline(__always)
    private func f(_ x: UInt32) -> UInt32 {
        ((s[Int(x >> 24)] &+ s[256 + Int(x >> 16 & 0xff)]) ^ s[512 + Int(x >> 8 & 0xff)]) &+ s[768 + Int(x & 0xff)]
    }

    private func encipher(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
        var l = left ^ p[0]
        var r = right
        var i = 1
        while i <= 16 {
            r ^= f(l) ^ p[i]
            l ^= f(r) ^ p[i + 1]
            i += 2
        }
        return (r ^ p[17], l)
    }

    private func expand0State(key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &j) }
        var l: UInt32 = 0, r: UInt32 = 0
        for i in Swift.stride(from: 0, to: 18, by: 2) {
            (l, r) = encipher(l, r)
            p[i] = l
            p[i + 1] = r
        }
        for i in Swift.stride(from: 0, to: 1024, by: 2) {
            (l, r) = encipher(l, r)
            s[i] = l
            s[i + 1] = r
        }
    }

    private func expandState(data: [UInt8], key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &j) }
        j = 0
        var l: UInt32 = 0, r: UInt32 = 0
        for i in Swift.stride(from: 0, to: 18, by: 2) {
            l ^= Self.streamToWord(data, &j)
            r ^= Self.streamToWord(data, &j)
            (l, r) = encipher(l, r)
            p[i] = l
            p[i + 1] = r
        }
        for i in Swift.stride(from: 0, to: 1024, by: 2) {
            l ^= Self.streamToWord(data, &j)
            r ^= Self.streamToWord(data, &j)
            (l, r) = encipher(l, r)
            s[i] = l
            s[i + 1] = r
        }
    }
}
