import Foundation

/// An S3 answer: status, body, and headers looked up case-insensitively.
struct S3Reply: @unchecked Sendable {
    let status: Int
    let body: Data
    let headers: [AnyHashable: Any]

    func header(_ name: String) -> String? {
        headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value as? String
    }

    private var xml: String { String(decoding: body, as: UTF8.self) }
    var errorCode: String? { TinyXML.value(of: "Code", in: xml) }
    var errorMessage: String { TinyXML.value(of: "Message", in: xml) ?? errorCode ?? "" }

    private static let expiredCodes: Set<String> = ["ExpiredToken", "TokenRefreshRequired", "InvalidToken"]

    var refusesCredentials: Bool {
        status == 403 || (status == 400 && errorCode.map(Self.expiredCodes.contains) == true)
    }

    /// Throws `RemoteStoreError` for any non-2xx answer.
    static func check(_ reply: S3Reply) throws {
        switch reply.status {
        case 200..<300: return
        case 401, 403: throw RemoteStoreError.unauthorized
        default: throw RemoteStoreError.http(status: reply.status, message: reply.errorMessage)
        }
    }
}

/// Text of the first `<tag>…</tag>`, entity-decoded. Enough for S3's flat answers; not a general XML parser.
enum TinyXML {
    static func value(of tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return decode(String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
