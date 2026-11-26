import Foundation

/// One entry of a folder listing, or the answer to `stat`.
public struct FileItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case file, directory, symlink, other
    }

    public let path: FilePath
    public let kind: Kind
    /// Bytes; nil when the source does not say (folders often do not).
    public let size: Int64?
    public let modified: Date?
    /// POSIX mode bits (0o755 ...) when the source has them.
    public let permissions: UInt32?

    public init(path: FilePath, kind: Kind, size: Int64? = nil, modified: Date? = nil, permissions: UInt32? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }

    public var id: FilePath { path }
    public var name: String { path.name }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }
}

/// What a source can do beyond list/stat/read/write. The transfer engine and the UI ask before they offer.
public struct FileCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `read(from: offset)` with offset > 0 (resume a download).
    public static let readAtOffset = FileCapabilities(rawValue: 1 << 0)
    /// `write(..., appendingAt: offset)` with offset > 0 (resume an upload).
    public static let writeAtOffset = FileCapabilities(rawValue: 1 << 1)
    /// `rename` within the source without copying.
    public static let rename = FileCapabilities(rawValue: 1 << 2)
    /// Real folders (object stores fake them with key prefixes).
    public static let directories = FileCapabilities(rawValue: 1 << 3)
    /// Writes are possible at all.
    public static let writable = FileCapabilities(rawValue: 1 << 4)

    public static let all: FileCapabilities = [.readAtOffset, .writeAtOffset, .rename, .directories, .writable]
}

public enum FileSourceError: Error, Equatable, LocalizedError {
    case notFound(FilePath)
    case alreadyExists(FilePath)
    case notADirectory(FilePath)
    case isADirectory(FilePath)
    case directoryNotEmpty(FilePath)
    case unsupported(String)
    case readOnly
    /// The copy landed with another size than the source: the source of a move is kept.
    case sizeMismatch(expected: Int64, actual: Int64)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): "\(path.name) does not exist."
        case .alreadyExists(let path): "\(path.name) already exists."
        case .notADirectory(let path): "\(path.name) is not a folder."
        case .isADirectory(let path): "\(path.name) is a folder."
        case .directoryNotEmpty(let path): "The folder \(path.name) is not empty."
        case .unsupported(let what): "This location cannot \(what)."
        case .readOnly: "This location is read-only."
        case let .sizeMismatch(expected, actual):
            "The copy has \(actual) bytes instead of \(expected); the original was kept."
        case .failed(let message): message
        }
    }
}

/// Reads a file front to back in chunks. Close it when done (also after an error).
public protocol FileReader: Sendable {
    /// Up to `maxLength` bytes; an empty `Data` at the end of the file.
    func read(maxLength: Int) async throws -> Data
    func close() async
}

/// Writes a file in chunks. `finish` makes it complete; `abort` stops and leaves what was written (for a resume).
public protocol FileWriter: Sendable {
    func write(_ data: Data) async throws
    func finish() async throws
    func abort() async
}

/// A place files live: the app's own folder, a folder picked in the Files app, an SFTP server, an S3 bucket, a
/// Drive. Every source speaks this protocol, so copy and move work between any two of them without pairwise code.
public protocol FileSource: Sendable {
    /// Stable within a run: the engine uses it to tell "same source" (a move can be a rename) from "another".
    var id: String { get }
    var displayName: String { get }
    var capabilities: FileCapabilities { get }
    /// Where browsing starts (a home folder for SFTP, "/" elsewhere).
    var home: FilePath { get }

    func list(_ directory: FilePath) async throws -> [FileItem]
    /// Throws `FileSourceError.notFound` when nothing is there.
    func stat(_ path: FilePath) async throws -> FileItem
    func reader(for path: FilePath, from offset: Int64) async throws -> any FileReader
    /// Offset 0 creates or truncates; offset > 0 appends there (needs `.writeAtOffset`).
    func writer(for path: FilePath, appendingAt offset: Int64) async throws -> any FileWriter
    /// A file, a symlink (not its target), or an empty folder.
    func delete(_ path: FilePath) async throws
    func rename(_ path: FilePath, to newPath: FilePath) async throws
    func makeDirectory(_ path: FilePath) async throws
}

extension FileSource {
    /// The item, or nil when nothing is there (other errors still throw).
    public func statIfExists(_ path: FilePath) async throws -> FileItem? {
        do { return try await stat(path) } catch FileSourceError.notFound { return nil }
    }

    /// A file or a whole folder tree, children first. Descends only into items whose listing kind is
    /// `.directory`: a symlink (listings report the link itself) is removed, never followed, so deleting a link to
    /// a folder cannot empty the folder it points at. Pass the item as listed, not as `stat` (which follows links)
    /// reports it.
    public func deleteRecursively(_ item: FileItem) async throws {
        if item.kind == .directory {
            for child in try await list(item.path) {
                try Task.checkCancellation()
                try await deleteRecursively(child)
            }
        }
        try await delete(item.path)
    }

    /// The whole file; only for small files (the text editor). Refuses past `limit` bytes.
    public func readAll(_ path: FilePath, limit: Int64 = 2 * 1024 * 1024) async throws -> Data {
        let item = try await stat(path)
        if let size = item.size, size > limit { throw FileSourceError.unsupported("open files over \(limit) bytes here") }
        let reader = try await reader(for: path, from: 0)
        var data = Data()
        do {
            while true {
                let chunk = try await reader.read(maxLength: 256 * 1024)
                if chunk.isEmpty { break }
                data.append(chunk)
                if Int64(data.count) > limit { throw FileSourceError.unsupported("open files over \(limit) bytes here") }
            }
        } catch {
            await reader.close()
            throw error
        }
        await reader.close()
        return data
    }

    /// Replaces the file with `data` (the text editor's save).
    public func writeAll(_ data: Data, to path: FilePath) async throws {
        let writer = try await writer(for: path, appendingAt: 0)
        do {
            try await writer.write(data)
            try await writer.finish()
        } catch {
            await writer.abort()
            throw error
        }
    }
}
