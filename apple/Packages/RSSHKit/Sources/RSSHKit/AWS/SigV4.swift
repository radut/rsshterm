import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AWS Signature Version 4 (header form) for one region and service. Pure: same request and date, same signature.
/// Signs every header the request carries plus Host, X-Amz-Date and, with temporary credentials,
/// X-Amz-Security-Token.
public struct SigV4Signer: Sendable {
    public static let algorithm = "AWS4-HMAC-SHA256"

    public let credentials: AWSCredentials
    public let region: String
    public let service: String

    public init(credentials: AWSCredentials, region: String, service: String) {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    /// A signed copy of `request` (method, URL, headers and body as set; a nil body signs as empty).
    public func sign(_ request: URLRequest, date: Date = Date()) -> URLRequest {
        guard let url = request.url else { return request }
        let headers = signedHeaders(method: request.httpMethod ?? "GET", url: url,
                                    headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? Data(), date: date)
        var signed = request
        signed.allHTTPHeaderFields = headers
        return signed
    }

    /// `headers` plus Host, X-Amz-Date, X-Amz-Security-Token (temporary credentials) and Authorization.
    public func signedHeaders(method: String, url: URL, headers: [String: String], body: Data, date: Date) -> [String: String] {
        let stamp = SigV4Time(date)
        var out = headers.filter { !Self.replaced.contains($0.key.lowercased()) }
        if !out.keys.contains(where: { $0.lowercased() == "host" }) { out["Host"] = Self.host(of: url) }
        out["X-Amz-Date"] = stamp.dateTime
        if let token = credentials.sessionToken { out["X-Amz-Security-Token"] = token }

        let canonical = SigV4Canonical(method: method, url: url, headers: out, body: body)
        let scope = "\(stamp.day)/\(region)/\(service)/aws4_request"
        let stringToSign = [Self.algorithm, stamp.dateTime, scope, Self.hex(SHA256.hash(data: Data(canonical.request.utf8)))]
            .joined(separator: "\n")
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey(day: stamp.day)))
        out["Authorization"] = "\(Self.algorithm) Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(canonical.signedHeaders), Signature=\(signature)"
        return out
    }

    private static let replaced: Set<String> = ["authorization", "x-amz-date", "x-amz-security-token"]

    private func signingKey(day: String) -> SymmetricKey {
        let secret = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        let keyDate = Self.hmac(secret, day)
        let keyRegion = Self.hmac(keyDate, region)
        let keyService = Self.hmac(keyRegion, service)
        return Self.hmac(keyService, "aws4_request")
    }

    private static func hmac(_ key: SymmetricKey, _ message: String) -> SymmetricKey {
        SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)))
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func host(of url: URL) -> String {
        let host = url.host ?? ""
        guard let port = url.port else { return host }
        let isDefault = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }
}

/// The two timestamps SigV4 uses, in UTC: 20150830T123600Z and 20150830.
struct SigV4Time {
    let dateTime: String
    let day: String

    init(_ date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        day = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        dateTime = day + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!)
    }
}
