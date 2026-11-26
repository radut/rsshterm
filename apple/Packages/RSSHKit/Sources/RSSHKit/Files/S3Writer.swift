import Foundation

/// Streams a file into S3: buffers up to one part; a file that fits in one part is a single PUT, anything larger a
/// multipart upload (create, one PUT per part, complete). `abort` cancels the multipart upload, so no parts linger.
actor S3Writer: FileWriter {
    private let client: S3Client
    private let key: String
    private let partSize: Int
    private var buffer = Data()
    private var uploadID: String?
    private var etags: [String] = []

    init(client: S3Client, key: String, partSize: Int) {
        self.client = client
        self.key = key
        self.partSize = partSize
    }

    func write(_ data: Data) async throws {
        buffer.append(data)
        while buffer.count >= partSize {
            let part = Data(buffer.prefix(partSize))
            buffer = Data(buffer.dropFirst(partSize))
            try await upload(part)
        }
    }

    func finish() async throws {
        guard uploadID != nil else {
            _ = try await client.checked("PUT", key: key, body: buffer)
            buffer = Data()
            return
        }
        if !buffer.isEmpty {
            try await upload(buffer)
            buffer = Data()
        }
        try await complete()
    }

    func abort() async {
        buffer = Data()
        guard let uploadID else { return }
        _ = try? await client.send("DELETE", key: key, query: [("uploadId", uploadID)])
        self.uploadID = nil
    }

    private func upload(_ part: Data) async throws {
        let id = try await startIfNeeded()
        let number = etags.count + 1
        let reply = try await client.checked("PUT", key: key, query: [("partNumber", String(number)), ("uploadId", id)],
                                             body: part)
        guard let etag = reply.header("ETag") else { throw RemoteStoreError.unexpectedResponse("no ETag for part \(number)") }
        etags.append(etag)
    }

    private func startIfNeeded() async throws -> String {
        if let uploadID { return uploadID }
        let reply = try await client.checked("POST", key: key, query: [("uploads", "")])
        guard let id = TinyXML.value(of: "UploadId", in: String(decoding: reply.body, as: UTF8.self)) else {
            throw RemoteStoreError.unexpectedResponse("no UploadId")
        }
        uploadID = id
        return id
    }

    private func complete() async throws {
        guard let uploadID else { return }
        let parts = etags.enumerated().map { index, etag in
            "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(Self.escape(etag))</ETag></Part>"
        }.joined()
        let body = Data("<CompleteMultipartUpload>\(parts)</CompleteMultipartUpload>".utf8)
        let reply = try await client.checked("POST", key: key, query: [("uploadId", uploadID)], body: body,
                                             headers: ["Content-Type": "application/xml"])
        // S3 can answer 200 with an error document when completion fails late.
        if TinyXML.value(of: "Code", in: String(decoding: reply.body, as: UTF8.self)) != nil {
            throw RemoteStoreError.http(status: 200, message: TinyXML.value(of: "Message", in: String(decoding: reply.body, as: UTF8.self)) ?? "")
        }
        self.uploadID = nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
