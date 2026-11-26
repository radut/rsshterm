import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one HTTP call remote stores make, so tests can answer without a network.
public protocol HTTPTransport: Sendable {
    /// Sends `request` and returns the body and response for any status code; throws only on transport failure.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPTransportError: Error, Equatable, LocalizedError {
    case notHTTP

    public var errorDescription: String? { "The server's answer was not an HTTP response." }
}

/// `HTTPTransport` over a `URLSession` (ephemeral by default: no cookies or cache kept on disk).
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPTransportError.notHTTP }
        return (data, http)
    }
}
