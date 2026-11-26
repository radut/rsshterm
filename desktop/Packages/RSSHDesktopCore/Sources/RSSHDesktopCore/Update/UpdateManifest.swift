import Crypto
import Foundation

public enum UpdateError: Error, Equatable, Sendable {
    /// latest.json.sig is missing or not base64 of 64 bytes.
    case unsigned
    /// The signature does not verify with any embedded key (or no key is embedded).
    case badSignature
    case badManifest(String)
    /// The manifest has no asset for this platform.
    case noAsset(String)
    case insecureURL(String)
    case checksumMismatch(expected: String, actual: String)
    case transport(String)
    case installFailed(String)
}

/// One downloadable build in latest.json.
public struct UpdateAsset: Codable, Equatable, Sendable {
    public let url: String
    /// Lowercase hex SHA-256 of the file.
    public let sha256: String

    public init(url: String, sha256: String) {
        self.url = url
        self.sha256 = sha256
    }
}

/// `<base>/desktop/latest.json` (schema: docs/desktop/update.md).
public struct UpdateManifest: Codable, Equatable, Sendable {
    public let version: String
    public let notes: String?
    public let published: String?
    /// Keyed by `UpdatePlatformKey` (linux-amd64, linux-arm64, macos-universal).
    public let assets: [String: UpdateAsset]

    public init(version: String, notes: String? = nil, published: String? = nil, assets: [String: UpdateAsset]) {
        self.version = version
        self.notes = notes
        self.published = published
        self.assets = assets
    }

    /// Parses verified bytes and checks every field: a semver version, https asset URLs, 64-hex checksums.
    static func decodeVerified(_ data: Data) throws(UpdateError) -> (UpdateManifest, SemanticVersion) {
        let manifest: UpdateManifest
        do { manifest = try JSONDecoder().decode(UpdateManifest.self, from: data) } catch {
            throw .badManifest("not the latest.json schema: \(error)")
        }
        guard let version = SemanticVersion(manifest.version) else { throw .badManifest("version \(manifest.version)") }
        for (key, asset) in manifest.assets {
            guard let url = URL(string: asset.url), url.scheme?.lowercased() == "https", url.host != nil else {
                throw .insecureURL(asset.url)
            }
            let hex = asset.sha256.lowercased()
            guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { throw .badManifest("sha256 of \(key)") }
        }
        return (manifest, version)
    }
}

/// The asset key for a platform and CPU.
public enum UpdatePlatformKey {
    public static func key(platform: Platform, architecture: String) -> String {
        switch platform {
        case .macOS: return "macos-universal"
        case .linux: return architecture == "aarch64" || architecture == "arm64" ? "linux-arm64" : "linux-amd64"
        }
    }

    /// The latest.json asset for an install: AppImages have their own (`linux-amd64-appimage`); deb and tarball
    /// installs use the tarball key (deb updates go through apt anyway).
    public static func key(for kind: InstallKind, architecture: String) -> String {
        switch kind {
        case .macApp: return key(platform: .macOS, architecture: architecture)
        case .appImage: return key(platform: .linux, architecture: architecture) + "-appimage"
        case .apt, .tarball, .unmanaged: return key(platform: .linux, architecture: architecture)
        }
    }

    /// This machine's CPU as `uname -m` says it.
    public static var currentArchitecture: String {
        #if arch(arm64)
        "aarch64"
        #else
        "x86_64"
        #endif
    }
}

/// The Ed25519 public keys the app trusts for latest.json (raw 32 bytes each). Verification happens on the exact
/// bytes downloaded, before they are parsed; an empty key list trusts nothing.
public struct UpdateTrust: Sendable {
    /// Raw 32-byte keys (swift-crypto's key type is not Sendable on every platform, its bytes are).
    private let rawKeys: [Data]

    public var publicKeys: [Curve25519.Signing.PublicKey] {
        rawKeys.compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    public init(publicKeys: [Curve25519.Signing.PublicKey]) { rawKeys = publicKeys.map(\.rawRepresentation) }

    /// Keys given as base64 of the raw 32 bytes; invalid entries are dropped.
    public init(base64Keys: [String]) {
        rawKeys = base64Keys.compactMap { Data(base64Encoded: $0) }.filter {
            (try? Curve25519.Signing.PublicKey(rawRepresentation: $0)) != nil
        }
    }

    /// The keys compiled into the app (UpdateSigningKeys.swift).
    public static let embedded = UpdateTrust(base64Keys: UpdateSigningKeys.base64)

    /// `signatureFile` is the content of latest.json.sig: base64 of the raw 64-byte signature (whitespace ignored).
    public func verify(_ manifest: Data, signatureFile: Data) throws(UpdateError) {
        let text = String(decoding: signatureFile, as: UTF8.self).filter { !$0.isWhitespace }
        guard let signature = Data(base64Encoded: text), signature.count == 64 else { throw .unsigned }
        guard publicKeys.contains(where: { $0.isValidSignature(signature, for: manifest) }) else { throw .badSignature }
    }
}
