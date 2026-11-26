import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetching for the updater, injectable for tests.
public protocol UpdateTransport: Sendable {
    /// The body of a 200 response; anything else throws.
    func data(from url: URL) async throws -> Data
    /// Saves the body of `url` to `file` (overwriting).
    func download(_ url: URL, to file: URL) async throws
}

/// URLSession, with no cookies or cache, so a stale latest.json is never served from a local cache.
public struct URLSessionUpdateTransport: UpdateTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try Self.check(response, url)
        return data
    }

    public func download(_ url: URL, to file: URL) async throws {
        let (temporary, response) = try await session.download(from: url)
        try Self.check(response, url)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private static func check(_ response: URLResponse, _ url: URL) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.transport("\(url.absoluteString): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }
}
