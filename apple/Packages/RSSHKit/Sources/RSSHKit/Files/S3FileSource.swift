import Foundation

/// An S3 bucket as a file source: "/" separated keys as paths, common prefixes as folders, an empty "name/" object
/// as a made folder. Reads are ranged GETs (so a download can resume); writes stream as a multipart upload in
/// parts of `partSize` (a single PUT when the file is smaller), so a file is never held in memory whole.
/// No rename and no write at an offset: a move within the bucket copies through the phone and deletes.
public struct S3FileSource: FileSource {
    public let id: String
    public let displayName: String
    public let capabilities: FileCapabilities = [.readAtOffset, .writable]
    public let home: FilePath = .root
    /// Multipart part size (S3's minimum is 5 MiB for every part but the last).
    public let partSize: Int
    /// Bytes fetched per ranged GET; reads hand them out in the engine's chunk size.
    public let rangeSize: Int
    let client: S3Client

    public init(bucket: String, region: String, credentials: any AWSCredentialProvider,
                transport: any HTTPTransport = URLSessionTransport(), displayName: String? = nil,
                partSize: Int = 8 * 1024 * 1024, rangeSize: Int = 4 * 1024 * 1024,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = S3Client(bucket: bucket, region: region, credentials: credentials, transport: transport, now: now)
        self.id = "s3:\(region)/\(bucket)"
        self.displayName = displayName ?? bucket
        self.partSize = max(partSize, 1)
        self.rangeSize = max(rangeSize, 1)
    }

    static func key(_ path: FilePath) -> String { path.segments.joined(separator: "/") }
    /// True when the key maps to a path and back unchanged. Keys with "//", "." or ".." segments do not; they are
    /// left out of listings, so no action can land on another object than the one listed.
    static func roundTrips(_ key: String) -> Bool { !key.isEmpty && Self.key(FilePath(key)) == key }

    static func prefix(_ directory: FilePath) -> String { directory.isRoot ? "" : key(directory) + "/" }

    // MARK: listing

    public func list(_ directory: FilePath) async throws -> [FileItem] {
        let page = try await listPage(prefix: Self.prefix(directory), limit: nil)
        if page.isEmpty, !directory.isRoot, try await statIfExists(directory) == nil { throw FileSourceError.notFound(directory) }
        return page.sorted { $0.path < $1.path }
    }

    /// Every entry right below `prefix`, following continuation tokens (or the first `limit`).
    private func listPage(prefix: String, limit: Int?) async throws -> [FileItem] {
        var items: [FileItem] = []
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("prefix", prefix), ("delimiter", "/")]
            if let limit { query.append(("max-keys", String(limit))) }
            if let token { query.append(("continuation-token", token)) }
            let xml = String(decoding: try await client.checked("GET", key: "", query: query).body, as: UTF8.self)
            for block in TinyXML.blocks(of: "Contents", in: xml) {
                guard let key = TinyXML.value(of: "Key", in: block), key != prefix, Self.roundTrips(key) else { continue }
                items.append(FileItem(path: FilePath(key), kind: .file, size: TinyXML.value(of: "Size", in: block).flatMap { Int64($0) },
                                      modified: S3Dates.parse(TinyXML.value(of: "LastModified", in: block))))
            }
            for block in TinyXML.blocks(of: "CommonPrefixes", in: xml) {
                guard let folder = TinyXML.value(of: "Prefix", in: block), Self.roundTrips(String(folder.dropLast())) else { continue }
                items.append(FileItem(path: FilePath(folder), kind: .directory))
            }
            token = TinyXML.value(of: "IsTruncated", in: xml) == "true" ? TinyXML.value(of: "NextContinuationToken", in: xml) : nil
        } while token != nil && limit == nil
        return items
    }

    public func stat(_ path: FilePath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: path, kind: .directory) }
        let head = try await client.send("HEAD", key: Self.key(path))
        if (200..<300).contains(head.status) {
            return FileItem(path: path, kind: .file, size: head.header("Content-Length").flatMap { Int64($0) },
                            modified: S3Dates.parse(head.header("Last-Modified")))
        }
        guard head.status == 404 else { try S3Reply.check(head); throw FileSourceError.notFound(path) }
        // A folder exists when anything (a marker or a file) has its prefix.
        let reply = try await client.checked("GET", key: "", query: [("list-type", "2"), ("prefix", Self.prefix(path)),
                                                                     ("max-keys", "1")])
        let xml = String(decoding: reply.body, as: UTF8.self)
        guard (Int(TinyXML.value(of: "KeyCount", in: xml) ?? "0") ?? 0) > 0 else { throw FileSourceError.notFound(path) }
        return FileItem(path: path, kind: .directory)
    }

    // MARK: bytes

    public func reader(for path: FilePath, from offset: Int64) async throws -> any FileReader {
        let item = try await stat(path)
        guard !item.isDirectory else { throw FileSourceError.isADirectory(path) }
        return S3Reader(client: client, key: Self.key(path), size: item.size ?? 0, offset: max(0, offset), rangeSize: rangeSize)
    }

    public func writer(for path: FilePath, appendingAt offset: Int64) async throws -> any FileWriter {
        if offset > 0 { throw FileSourceError.unsupported("resume a write") }
        return S3Writer(client: client, key: Self.key(path), partSize: partSize)
    }

    // MARK: changes

    public func delete(_ path: FilePath) async throws {
        guard !path.isRoot else { throw FileSourceError.unsupported("delete the root") }
        let item = try await stat(path)
        if item.isDirectory {
            let below = try await listPage(prefix: Self.prefix(path), limit: 2)
            if !below.isEmpty { throw FileSourceError.directoryNotEmpty(path) }
            _ = try await client.checked("DELETE", key: Self.prefix(path))
        } else {
            _ = try await client.checked("DELETE", key: Self.key(path))
        }
    }

    public func rename(_ path: FilePath, to newPath: FilePath) async throws {
        throw FileSourceError.unsupported("rename")
    }

    public func makeDirectory(_ path: FilePath) async throws {
        if try await statIfExists(path) != nil { throw FileSourceError.alreadyExists(path) }
        _ = try await client.checked("PUT", key: Self.prefix(path))
    }
}

/// Ranged GETs of `rangeSize`, handed out in the caller's chunks.
actor S3Reader: FileReader {
    private let client: S3Client
    private let key: String
    private let size: Int64
    private let rangeSize: Int
    private var offset: Int64
    private var buffer = Data()

    init(client: S3Client, key: String, size: Int64, offset: Int64, rangeSize: Int) {
        self.client = client
        self.key = key
        self.size = size
        self.offset = offset
        self.rangeSize = rangeSize
    }

    func read(maxLength: Int) async throws -> Data {
        if buffer.isEmpty, offset < size {
            let end = min(offset + Int64(rangeSize), size) - 1
            let reply = try await client.checked("GET", key: key, headers: ["Range": "bytes=\(offset)-\(end)"])
            guard !reply.body.isEmpty else { throw RemoteStoreError.unexpectedResponse("empty range") }
            buffer = reply.body
            offset += Int64(reply.body.count)
        }
        let chunk = buffer.prefix(maxLength)
        buffer = Data(buffer.dropFirst(chunk.count))
        return Data(chunk)
    }

    func close() { buffer = Data() }
}
