import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Drive v3 REST requests for the one vault file in the app's hidden appDataFolder.
/// https://developers.google.com/workspace/drive/api/guides/appdata
enum DriveRequests {
    static let api = "https://www.googleapis.com/drive/v3/files"
    static let upload = "https://www.googleapis.com/upload/drive/v3/files"
    static let fileFields = "id,version,headRevisionId"

    /// files.list in appDataFolder by name, newest first (a duplicate from a racing create is ignored).
    static func find(name: String) -> URLRequest {
        request("GET", api, query: [
            ("spaces", "appDataFolder"),
            ("q", "name = '\(name)' and trashed = false"),
            ("orderBy", "modifiedTime desc"),
            ("fields", "files(\(fileFields))"),
        ])
    }

    static func download(fileID: String) -> URLRequest {
        request("GET", "\(api)/\(fileID)", query: [("alt", "media")])
    }

    /// files.create with a multipart/related body: JSON metadata, then the content.
    static func create(name: String, data: Data, boundary: String = UUID().uuidString) -> URLRequest {
        var req = request("POST", upload, query: [("uploadType", "multipart"), ("fields", fileFields)])
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let metadata = #"{"name":"\#(name)","parents":["appDataFolder"]}"#
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(metadata)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        return req
    }

    /// files.update replacing the content only.
    static func update(fileID: String, data: Data) -> URLRequest {
        var req = request("PATCH", "\(upload)/\(fileID)", query: [("uploadType", "media"), ("fields", fileFields)])
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        return req
    }

    private static func request(_ method: String, _ base: String, query: [(String, String)]) -> URLRequest {
        let encoded = query.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
        // The base strings are constants and the ids come from Drive's own answers, so this URL always parses.
        var req = URLRequest(url: URL(string: "\(base)?\(encoded)")!)
        req.httpMethod = method
        return req
    }

    /// Strict percent-encoding (RFC 3986 unreserved only), so `=`, `'` and `&` inside a value stay inside it.
    private static func escape(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}

/// The parts of a Drive `File` resource this store reads.
struct DriveFile: Decodable, Sendable {
    let id: String
    let version: String?
    let headRevisionId: String?

    /// Drive's `version` increases on every change to the file; `headRevisionId` is the fallback.
    var revision: String? { version ?? headRevisionId }
}

struct DriveFileList: Decodable {
    let files: [DriveFile]
}

struct DriveErrorBody: Decodable {
    struct Inner: Decodable { let message: String? }
    let error: Inner?
}
