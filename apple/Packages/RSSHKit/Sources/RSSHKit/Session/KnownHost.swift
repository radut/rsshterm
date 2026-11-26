import Crypto
import Foundation

/// A server host key the user has trusted (trust on first use, then pinned). Stored in the `Vault`.
public struct KnownHost: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    /// SSH algorithm name, e.g. "ssh-ed25519", "ssh-rsa".
    public var keyType: String
    /// "SHA256:<unpadded base64>", the form `ssh-keygen -lf` prints.
    public var fingerprint: String
    /// When the user trusted it; nil for pins made before dates were kept. Not part of the pin's identity.
    public var addedAt: Date?

    public init(host: String, port: Int, keyType: String, fingerprint: String, addedAt: Date? = nil) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.addedAt = addedAt
    }

    public static func == (lhs: KnownHost, rhs: KnownHost) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port && lhs.keyType == rhs.keyType && lhs.fingerprint == rhs.fingerprint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(port)
        hasher.combine(keyType)
        hasher.combine(fingerprint)
    }

    /// A copy stamped with the moment the user trusted it.
    public func trusted(at date: Date) -> KnownHost {
        KnownHost(host: host, port: port, keyType: keyType, fingerprint: fingerprint, addedAt: date)
    }

    func isSameEndpoint(as other: KnownHost) -> Bool { isEndpoint(host: other.host, port: other.port) }

    func isEndpoint(host: String, port: Int) -> Bool {
        self.port == port && self.host.lowercased() == host.lowercased()
    }
}

/// SHA-256 fingerprints of SSH public keys.
public enum HostKeyFingerprint {
    public enum ParseError: Error, Equatable { case notAPublicKey, badBase64, typeMismatch }

    public static func sha256(blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Reads an OpenSSH public key line ("ssh-ed25519 AAAA… comment") and fingerprints its key blob.
    public static func parse(openSSHPublicKey line: String) throws(ParseError) -> (keyType: String, fingerprint: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw .notAPublicKey }
        guard let blob = Data(base64Encoded: String(parts[1])) else { throw .badBase64 }
        var reader = SSHWireReader(blob)
        guard let blobType = try? reader.text() else { throw .notAPublicKey }
        guard blobType == String(parts[0]) else { throw .typeMismatch }
        return (blobType, sha256(blob: blob))
    }
}

public enum HostKeyDecision: Equatable, Sendable {
    /// The presented key is the pinned one.
    case accept
    /// Never seen this host: show the fingerprint and let the user decide.
    case ask
    /// The host is pinned to another key: possible man-in-the-middle, refuse.
    case refuse(expected: KnownHost)
}

/// Trust on first use: unknown -> ask, match -> accept, mismatch -> refuse.
public enum HostKeyPolicy {
    public static func evaluate(_ presented: KnownHost, against known: [KnownHost]) -> HostKeyDecision {
        let pinned = known.filter { $0.isSameEndpoint(as: presented) }
        guard let first = pinned.first else { return .ask }
        let matches = pinned.contains { $0.keyType == presented.keyType && $0.fingerprint == presented.fingerprint }
        return matches ? .accept : .refuse(expected: first)
    }

    /// The list with `host` pinned after the user accepted it, but only while its endpoint is still unknown: a pin
    /// added meanwhile (another session, a sync) is never replaced. nil when the endpoint is pinned to another key.
    public static func pinning(_ host: KnownHost, in known: [KnownHost]) -> [KnownHost]? {
        switch evaluate(host, against: known) {
        case .ask: return known + [host]
        case .accept: return known
        case .refuse: return nil
        }
    }

    /// The list with `host` trusted: any older key for the same host and port is replaced. Only for an explicit
    /// "forget the old key and trust this one" by the user.
    public static func trusting(_ host: KnownHost, in known: [KnownHost]) -> [KnownHost] {
        known.filter { !$0.isSameEndpoint(as: host) } + [host]
    }

    /// The list with `expected` (the pin the user was shown) replaced by `presented`, after the user chose
    /// "Replace and Connect" on a changed key. nil when the endpoint's pin is no longer `expected`: something changed
    /// meanwhile, so nothing is replaced.
    public static func replacing(_ expected: KnownHost, with presented: KnownHost,
                                 in known: [KnownHost]) -> [KnownHost]? {
        let pinned = known.filter { $0.isSameEndpoint(as: presented) }
        guard pinned.contains(expected) else { return nil }
        return trusting(presented, in: known)
    }

    public static func forgetting(host: String, port: Int, in known: [KnownHost]) -> [KnownHost] {
        known.filter { !$0.isEndpoint(host: host, port: port) }
    }
}
