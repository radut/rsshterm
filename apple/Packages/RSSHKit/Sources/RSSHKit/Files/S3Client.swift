import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SigV4-signed S3 requests for any key of one bucket, with one retry on fresh credentials when S3 refuses them.
/// The file source and its multipart writer use it.
struct S3Client: Sendable {
    let bucket: String
    let region: String
    let credentials: any AWSCredentialProvider
    let transport: any HTTPTransport
    let now: @Sendable () -> Date

    func send(_ method: String, key: String, query: [(String, String)] = [], body: Data = Data(),
              headers: [String: String] = [:]) async throws -> S3Reply {
        let first = try await attempt(method, key: key, query: query, body: body, headers: headers)
        guard first.refusesCredentials else { return first }
        await credentials.invalidate()
        return try await attempt(method, key: key, query: query, body: body, headers: headers)
    }

    /// Like `send`, but any non-2xx answer throws (`RemoteStoreError`).
    func checked(_ method: String, key: String, query: [(String, String)] = [], body: Data = Data(),
                 headers: [String: String] = [:]) async throws -> S3Reply {
        let reply = try await send(method, key: key, query: query, body: body, headers: headers)
        try S3Reply.check(reply)
        return reply
    }

    private func attempt(_ method: String, key: String, query: [(String, String)], body: Data,
                         headers: [String: String]) async throws -> S3Reply {
        guard let url = url(key: key, query: query) else { throw RemoteStoreError.http(status: 400, message: "bad key") }
        let creds = try await credentials.credentials()
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(SigV4Signer.hex(SHA256.hash(data: body)), forHTTPHeaderField: "x-amz-content-sha256")
        if !body.isEmpty || method == "PUT" || method == "POST" { request.httpBody = body }
        let signed = SigV4Signer(credentials: creds, region: region, service: "s3").sign(request, date: now())
        let (data, response) = try await transport.send(signed)
        return S3Reply(status: response.statusCode, body: data, headers: response.allHeaderFields)
    }

    /// Virtual-hosted style; path style for buckets with dots (their names break the wildcard certificate).
    func url(key: String, query: [(String, String)]) -> URL? {
        let path = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { SigV4Canonical.encode(String($0)) }.joined(separator: "/")
        let base = bucket.contains(".")
            ? "https://s3.\(region).amazonaws.com/\(SigV4Canonical.encode(bucket))"
            : "https://\(bucket).s3.\(region).amazonaws.com"
        let queryString = query.map { name, value in
            value.isEmpty && name == "uploads" ? name : "\(SigV4Canonical.encode(name))=\(SigV4Canonical.encode(value))"
        }.joined(separator: "&")
        return URL(string: "\(base)/\(path)" + (queryString.isEmpty ? "" : "?\(queryString)"))
    }
}

extension TinyXML {
    /// The inner text of every `<tag>...</tag>` in order.
    static func blocks(of tag: String, in xml: String) -> [String] {
        var out: [String] = []
        var rest = xml[...]
        while let open = rest.range(of: "<\(tag)>"), let close = rest.range(of: "</\(tag)>", range: open.upperBound..<rest.endIndex) {
            out.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return out
    }
}

/// S3's dates: ISO 8601 with fractions in listings, RFC 1123 in Last-Modified headers.
enum S3Dates {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let http = DateFormatter()
        http.locale = Locale(identifier: "en_US_POSIX")
        http.timeZone = TimeZone(identifier: "GMT")
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return http.date(from: text)
    }
}
