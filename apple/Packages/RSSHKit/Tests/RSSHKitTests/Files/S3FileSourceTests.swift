import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RSSHKit

/// A tiny in-memory S3 bucket behind `HTTPTransport`: ListObjectsV2 with delimiter, HEAD, ranged GET, PUT, DELETE
/// and multipart uploads. Records the method and query of every request.
actor FakeS3Bucket: HTTPTransport {
    var objects: [String: Data] = [:]
    var uploads: [String: [Int: Data]] = [:]
    private(set) var log: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let key = String(components.path.dropFirst())
        let method = request.httpMethod ?? "GET"
        log.append("\(method) \(key) \(query.keys.sorted().joined(separator: ","))")
        let (status, body, headers) = handle(method, key: key, query: query, request: request)
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    private func handle(_ method: String, key: String, query: [String: String],
                        request: URLRequest) -> (Int, Data, [String: String]) {
        switch method {
        case "GET" where query["list-type"] == "2": return (200, Data(listing(query).utf8), [:])
        case "HEAD":
            guard let data = objects[key] else { return (404, Data(), [:]) }
            return (200, Data(), ["Content-Length": "\(data.count)", "Last-Modified": "Tue, 24 Nov 2026 10:00:00 GMT"])
        case "GET":
            guard let data = objects[key] else { return (404, Data("<Error><Code>NoSuchKey</Code></Error>".utf8), [:]) }
            if let range = request.value(forHTTPHeaderField: "Range")?.dropFirst(6).split(separator: "-"),
               let start = Int(range[0]), let end = Int(range[1]) {
                return (206, data.subdata(in: start..<min(end + 1, data.count)), [:])
            }
            return (200, data, [:])
        case "PUT" where query["uploadId"] != nil:
            uploads[query["uploadId"]!, default: [:]][Int(query["partNumber"]!)!] = request.httpBody ?? Data()
            return (200, Data(), ["ETag": "\"etag-\(query["partNumber"]!)\""])
        case "PUT":
            objects[key] = request.httpBody ?? Data()
            return (200, Data(), ["ETag": "\"x\""])
        case "POST" where query["uploads"] != nil:
            let id = "upload-\(uploads.count + 1)"
            uploads[id] = [:]
            return (200, Data("<InitiateMultipartUploadResult><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>".utf8), [:])
        case "POST" where query["uploadId"] != nil:
            let parts = uploads.removeValue(forKey: query["uploadId"]!) ?? [:]
            objects[key] = parts.keys.sorted().reduce(into: Data()) { $0.append(parts[$1]!) }
            return (200, Data("<CompleteMultipartUploadResult/>".utf8), [:])
        case "DELETE" where query["uploadId"] != nil:
            uploads[query["uploadId"]!] = nil
            return (204, Data(), [:])
        case "DELETE":
            objects[key] = nil
            return (204, Data(), [:])
        default: return (400, Data(), [:])
        }
    }

    private func listing(_ query: [String: String]) -> String {
        let prefix = query["prefix"] ?? ""
        let delimiter = query["delimiter"]
        var contents: [String] = []
        var prefixes: Set<String> = []
        for key in objects.keys.sorted() where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if let delimiter, let cut = rest.range(of: delimiter) {
                prefixes.insert(prefix + rest[..<cut.upperBound])
            } else {
                contents.append("<Contents><Key>\(key)</Key><Size>\(objects[key]!.count)</Size>"
                                + "<LastModified>2026-11-24T10:00:00.000Z</LastModified></Contents>")
            }
        }
        let limit = Int(query["max-keys"] ?? "1000") ?? 1000
        let all = contents + prefixes.sorted().map { "<CommonPrefixes><Prefix>\($0)</Prefix></CommonPrefixes>" }
        let shown = all.prefix(limit)
        return "<ListBucketResult><KeyCount>\(shown.count)</KeyCount><IsTruncated>false</IsTruncated>\(shown.joined())</ListBucketResult>"
    }

    func put(_ key: String, _ data: Data) { objects[key] = data }
    func clearLog() { log = [] }
}

@Suite struct S3FileSourceTests {
    func make(partSize: Int = 8, rangeSize: Int = 5) -> (S3FileSource, FakeS3Bucket) {
        let bucket = FakeS3Bucket()
        let source = S3FileSource(bucket: "files", region: "eu-central-1", credentials: FixedCredentials(),
                                  transport: bucket, partSize: partSize, rangeSize: rangeSize)
        return (source, bucket)
    }

    @Test func listsPrefixesAsFoldersAndKeysAsFiles() async throws {
        let (source, bucket) = make()
        await bucket.put("docs/a.txt", Data("hello".utf8))
        await bucket.put("docs/sub/b.txt", Data("b".utf8))
        await bucket.put("docs/", Data())   // folder marker
        await bucket.put("top.bin", Data(count: 3))
        let root = try await source.list(.root)
        #expect(root.map(\.name) == ["docs", "top.bin"])
        #expect(root[0].isDirectory && root[1].size == 3)
        let docs = try await source.list(FilePath("/docs"))
        #expect(docs.map(\.name) == ["a.txt", "sub"])
        #expect(docs[0].modified != nil)
        #expect(try await source.stat(FilePath("/docs/sub")).isDirectory)
        #expect(try await source.stat(FilePath("/docs/a.txt")).size == 5)
        await #expect(throws: FileSourceError.notFound(FilePath("/nope"))) { try await source.stat(FilePath("/nope")) }
    }

    @Test func keysThatDoNotRoundTripAreLeftOut() async throws {
        let (source, bucket) = make()
        for key in ["a/../b", "x//y", "./c", "ok.txt", "dir/./z"] { await bucket.put(key, Data("1".utf8)) }
        await bucket.put("b", Data("keep".utf8))
        let root = try await source.list(.root)
        // "a/", "x/" and "dir/" are real prefixes; "./" is not a usable folder name.
        #expect(root.map(\.name) == ["a", "b", "dir", "ok.txt", "x"])
        #expect(try await source.list(FilePath("/a")).isEmpty)      // "a/../" is left out
        #expect(try await source.list(FilePath("/x")).isEmpty)      // "x//y" is left out
        #expect(await bucket.objects["b"] == Data("keep".utf8))
    }

    @Test func readsInRangesFromAnOffset() async throws {
        let (source, bucket) = make(rangeSize: 4)
        await bucket.put("f", Data("0123456789".utf8))
        let reader = try await source.reader(for: FilePath("/f"), from: 3)
        var out = Data()
        while true {
            let chunk = try await reader.read(maxLength: 3)
            if chunk.isEmpty { break }
            out.append(chunk)
        }
        #expect(out == Data("3456789".utf8))
        #expect(await bucket.log.filter { $0.hasPrefix("GET f") }.count == 2)   // 3-6, 7-9
    }

    @Test func smallFileIsOnePut() async throws {
        let (source, bucket) = make(partSize: 100)
        try await source.writeAll(Data("small".utf8), to: FilePath("/dir/s.txt"))
        #expect(await bucket.objects["dir/s.txt"] == Data("small".utf8))
        #expect(await bucket.log.contains { $0.hasPrefix("POST") } == false)
    }

    @Test func largeFileStreamsAsMultipart() async throws {
        let (source, bucket) = make(partSize: 4)
        let writer = try await source.writer(for: FilePath("/big"), appendingAt: 0)
        for piece in ["abc", "defgh", "ij"] { try await writer.write(Data(piece.utf8)) }
        try await writer.finish()
        #expect(await bucket.objects["big"] == Data("abcdefghij".utf8))
        #expect(await bucket.log.filter { $0.hasPrefix("PUT big partNumber") }.count == 3)
        #expect(await bucket.uploads.isEmpty)
    }

    @Test func abortCancelsTheMultipartUpload() async throws {
        let (source, bucket) = make(partSize: 2)
        let writer = try await source.writer(for: FilePath("/big"), appendingAt: 0)
        try await writer.write(Data("abcde".utf8))
        await writer.abort()
        #expect(await bucket.uploads.isEmpty)
        #expect(await bucket.objects["big"] == nil)
    }

    @Test func foldersAreMarkersAndDeleteOnlyWhenEmpty() async throws {
        let (source, bucket) = make()
        try await source.makeDirectory(FilePath("/new"))
        #expect(await bucket.objects["new/"] == Data())
        try await source.writeAll(Data("x".utf8), to: FilePath("/new/f"))
        await #expect(throws: FileSourceError.directoryNotEmpty(FilePath("/new"))) { try await source.delete(FilePath("/new")) }
        try await source.deleteRecursively(try await source.stat(FilePath("/new")))
        #expect(await bucket.objects.isEmpty)
    }

    @Test func refusesRenameAndOffsetWrites() async throws {
        let (source, _) = make()
        await #expect(throws: FileSourceError.unsupported("rename")) { try await source.rename(FilePath("/a"), to: FilePath("/b")) }
        await #expect(throws: FileSourceError.unsupported("resume a write")) {
            try await source.writer(for: FilePath("/a"), appendingAt: 1)
        }
    }

    @Test func copiesBetweenS3AndAnotherSourceThroughTheEngine() async throws {
        let (source, bucket) = make(partSize: 64, rangeSize: 50)
        let local = MemoryFileSource()
        let bytes = Data((0..<300).map { UInt8($0 % 256) })
        await local.seed(FilePath("/up/data.bin"), bytes)
        let engine = TransferEngine(chunkSize: 40)
        let up = await engine.enqueue(TransferRequest(source: local, items: [FilePath("/up")], destination: source,
                                                      destinationDirectory: .root, operation: .copy))
        #expect(await engine.waitUntilFinished(up)?.state == .completed)
        #expect(await bucket.objects["up/data.bin"] == bytes)
        let down = await engine.enqueue(TransferRequest(source: source, items: [FilePath("/up/data.bin")], destination: local,
                                                        destinationDirectory: .root, operation: .move))
        #expect(await engine.waitUntilFinished(down)?.state == .completed)
        #expect(await local.contents(of: FilePath("/data.bin")) == bytes)
        #expect(await bucket.objects["up/data.bin"] == nil)
    }

    @Test func urlsEncodeKeysAndQueries() {
        let client = S3Client(bucket: "files", region: "eu-central-1", credentials: FixedCredentials(),
                              transport: FakeS3Bucket(), now: { Date() })
        #expect(client.url(key: "a b/c+d", query: [("prefix", "x y/")])?.absoluteString
                == "https://files.s3.eu-central-1.amazonaws.com/a%20b/c%2Bd?prefix=x%20y%2F")
        #expect(client.url(key: "k", query: [("uploads", "")])?.absoluteString == "https://files.s3.eu-central-1.amazonaws.com/k?uploads")
    }
}
