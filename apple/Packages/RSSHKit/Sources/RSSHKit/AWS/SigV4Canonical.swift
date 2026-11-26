import Crypto
import Foundation

/// The canonical request of SigV4: method, URI, query, headers, signed header list, payload hash.
struct SigV4Canonical {
    let request: String
    let signedHeaders: String

    init(method: String, url: URL, headers: [String: String], body: Data) {
        let sorted = headers
            .map { (name: $0.key.lowercased(), value: Self.trim($0.value)) }
            .sorted { $0.name < $1.name }
        signedHeaders = sorted.map(\.name).joined(separator: ";")
        let headerBlock = sorted.map { "\($0.name):\($0.value)\n" }.joined()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        request = [
            method.uppercased(),
            Self.uri(components?.percentEncodedPath ?? ""),
            Self.query(components?.percentEncodedQuery),
            headerBlock,
            signedHeaders,
            SigV4Signer.hex(SHA256.hash(data: body)),
        ].joined(separator: "\n")
    }

    /// Each path segment decoded once and encoded with RFC 3986's unreserved set.
    static func uri(_ encodedPath: String) -> String {
        guard !encodedPath.isEmpty else { return "/" }
        return encodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0).removingPercentEncoding ?? String($0)) }
            .joined(separator: "/")
    }

    /// Parameters decoded, re-encoded, sorted by name then value.
    static func query(_ encodedQuery: String?) -> String {
        guard let encodedQuery, !encodedQuery.isEmpty else { return "" }
        let pairs = encodedQuery.split(separator: "&").map { param(String($0)) }
        let sorted = pairs.sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    private static func param(_ pair: String) -> (name: String, value: String) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0].removingPercentEncoding ?? parts[0]
        let raw = parts.count > 1 ? parts[1] : ""
        let value = raw.removingPercentEncoding ?? raw
        return (encode(name), encode(value))
    }

    /// Leading/trailing whitespace removed and inner runs (spaces, tabs, folded lines) collapsed to one space.
    static func trim(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)

    static func encode(_ s: String) -> String {
        s.utf8.map { (byte: UInt8) -> String in
            unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }
}
