import Crypto
import Foundation

/// A newer build for this machine.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: SemanticVersion
    public let notes: String?
    public let assetKey: String
    public let asset: UpdateAsset

    public init(version: SemanticVersion, notes: String?, assetKey: String, asset: UpdateAsset) {
        self.version = version
        self.notes = notes
        self.assetKey = assetKey
        self.asset = asset
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(latest: SemanticVersion)
    case available(AvailableUpdate)
}

/// Reads `<base>/desktop/latest.json` and its detached signature and decides whether a newer build exists.
public struct UpdateChecker: Sendable {
    public static let defaultBaseURL = URL(string: "https://rssh-ea902a.gitlab.io")!

    public let baseURL: URL
    public let transport: any UpdateTransport
    public let trust: UpdateTrust

    public init(baseURL: URL = UpdateChecker.defaultBaseURL, transport: any UpdateTransport = URLSessionUpdateTransport(),
                trust: UpdateTrust = .embedded) {
        self.baseURL = baseURL
        self.transport = transport
        self.trust = trust
    }

    public var manifestURL: URL { baseURL.appendingPathComponent("desktop/latest.json") }
    public var signatureURL: URL { baseURL.appendingPathComponent("desktop/latest.json.sig") }

    /// Downloads, verifies the signature over the exact bytes, then parses. Only a strictly newer version is an
    /// update, so a replayed old manifest can never downgrade.
    public func check(current: SemanticVersion, assetKey: String) async throws(UpdateError) -> UpdateCheckResult {
        let manifestData: Data
        let signature: Data
        do {
            manifestData = try await transport.data(from: manifestURL)
        } catch { throw Self.transportError(error) }
        do {
            signature = try await transport.data(from: signatureURL)
        } catch { throw .unsigned }
        try trust.verify(manifestData, signatureFile: signature)
        let (manifest, latest) = try UpdateManifest.decodeVerified(manifestData)
        guard latest > current else { return .upToDate(latest: latest) }
        guard let asset = manifest.assets[assetKey] else { throw .noAsset(assetKey) }
        return .available(AvailableUpdate(version: latest, notes: manifest.notes, assetKey: assetKey, asset: asset))
    }

    /// Downloads the asset into `directory` and checks its SHA-256; a mismatch deletes the file.
    public func download(_ update: AvailableUpdate, into directory: URL) async throws(UpdateError) -> URL {
        guard let url = URL(string: update.asset.url), url.scheme?.lowercased() == "https" else {
            throw .insecureURL(update.asset.url)
        }
        let name = url.lastPathComponent.isEmpty ? "update.bin" : url.lastPathComponent
        let file = directory.appendingPathComponent(name)
        do { try await transport.download(url, to: file) } catch { throw Self.transportError(error) }
        let actual: String
        do { actual = try Self.sha256(of: file) } catch { throw .installFailed("read \(file.path): \(error)") }
        guard actual == update.asset.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: file)
            throw .checksumMismatch(expected: update.asset.sha256.lowercased(), actual: actual)
        }
        return file
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func transportError(_ error: any Error) -> UpdateError {
        (error as? UpdateError) ?? .transport(String(describing: error))
    }
}
