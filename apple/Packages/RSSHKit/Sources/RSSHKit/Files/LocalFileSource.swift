import Foundation

/// A folder on the device as a file source: the app's "My Files" (its Documents folder) or a folder the user
/// picked in the Files app. Paths are relative to `rootURL` and `FilePath` cannot climb above it.
/// Security-scoped URLs (picked folders) must be opened by the caller for as long as the source is used.
public struct LocalFileSource: FileSource {
    public let id: String
    public let displayName: String
    public let rootURL: URL
    public let capabilities: FileCapabilities = .all
    public let home: FilePath = .root

    public init(rootURL: URL, displayName: String, id: String? = nil) {
        self.rootURL = rootURL.standardizedFileURL
        self.displayName = displayName
        self.id = id ?? "local:" + rootURL.standardizedFileURL.path
    }

    /// The device URL of a path in this source.
    public func url(for path: FilePath) -> URL {
        path.segments.reduce(rootURL) { $0.appendingPathComponent($1) }
    }

    public func list(_ directory: FilePath) async throws -> [FileItem] {
        guard try item(at: directory).isDirectory else { throw FileSourceError.notADirectory(directory) }
        let names = try FileManager.default.contentsOfDirectory(atPath: url(for: directory).path)
        return names.sorted().compactMap { try? self.item(at: directory.appending($0)) }
    }

    public func stat(_ path: FilePath) async throws -> FileItem { try item(at: path) }

    private func item(at path: FilePath) throws -> FileItem {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url(for: path).path) } catch {
            throw FileSourceError.notFound(path)
        }
        let type = attributes[.type] as? FileAttributeType
        let kind: FileItem.Kind = switch type {
        case .typeDirectory?: .directory
        case .typeRegular?: .file
        case .typeSymbolicLink?: .symlink
        default: .other
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint32Value
        return FileItem(path: path, kind: kind, size: kind == .directory ? nil : size,
                        modified: attributes[.modificationDate] as? Date, permissions: mode)
    }

    public func reader(for path: FilePath, from offset: Int64) async throws -> any FileReader {
        let item = try item(at: path)
        guard !item.isDirectory else { throw FileSourceError.isADirectory(path) }
        let handle = try FileHandle(forReadingFrom: url(for: path))
        if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
        return LocalReader(handle: handle)
    }

    public func writer(for path: FilePath, appendingAt offset: Int64) async throws -> any FileWriter {
        let target = url(for: path)
        guard (try? item(at: path.parent))?.isDirectory == true else { throw FileSourceError.notFound(path.parent) }
        if (try? item(at: path))?.isDirectory == true { throw FileSourceError.isADirectory(path) }
        if offset == 0 || !FileManager.default.fileExists(atPath: target.path) {
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw FileSourceError.failed("Cannot create \(path.name).")
            }
        }
        let handle = try FileHandle(forWritingTo: target)
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seek(toOffset: UInt64(offset))
        return LocalWriter(handle: handle)
    }

    public func delete(_ path: FilePath) async throws {
        guard !path.isRoot else { throw FileSourceError.unsupported("delete the root") }
        let item = try item(at: path)
        if item.isDirectory, !(try FileManager.default.contentsOfDirectory(atPath: url(for: path).path)).isEmpty {
            throw FileSourceError.directoryNotEmpty(path)
        }
        try FileManager.default.removeItem(at: url(for: path))
    }

    public func rename(_ path: FilePath, to newPath: FilePath) async throws {
        guard !path.isRoot else { throw FileSourceError.unsupported("rename the root") }
        if (try? item(at: newPath)) != nil { throw FileSourceError.alreadyExists(newPath) }
        _ = try item(at: path)
        try FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))
    }

    public func makeDirectory(_ path: FilePath) async throws {
        if (try? item(at: path)) != nil { throw FileSourceError.alreadyExists(path) }
        guard (try? item(at: path.parent))?.isDirectory == true else { throw FileSourceError.notFound(path.parent) }
        try FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: false)
    }
}

/// FileHandle is not Sendable; the actor owns it.
actor LocalReader: FileReader {
    private let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }

    func read(maxLength: Int) throws -> Data { try handle.read(upToCount: maxLength) ?? Data() }
    func close() { try? handle.close() }
}

actor LocalWriter: FileWriter {
    private let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }

    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func finish() throws {
        try handle.synchronize()
        try handle.close()
    }
    func abort() { try? handle.close() }
}
