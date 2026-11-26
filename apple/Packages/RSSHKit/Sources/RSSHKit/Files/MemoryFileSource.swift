import Foundation

/// A file source held in memory: the fake for tests and the sample data for screenshots (`-sampleData`).
/// Capabilities can be narrowed to imitate an object store (no offsets, no rename).
public final class MemoryFileSource: FileSource {
    public let id: String
    public let displayName: String
    public let capabilities: FileCapabilities
    public let home: FilePath
    let store: MemoryFileStore

    public init(id: String = UUID().uuidString, displayName: String = "Memory",
                capabilities: FileCapabilities = .all, home: FilePath = .root) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.home = home
        self.store = MemoryFileStore()
    }

    /// Adds a file (and its folders) directly, for setting up tests and samples.
    public func seed(_ path: FilePath, _ data: Data, modified: Date = Date(timeIntervalSince1970: 1_790_000_000)) async {
        await store.seed(path, data, modified: modified)
    }

    public func seedDirectory(_ path: FilePath) async { await store.mkdirs(path) }

    /// The content of a file, or nil.
    public func contents(of path: FilePath) async -> Data? { await store.files[path] }

    public func list(_ directory: FilePath) async throws -> [FileItem] { try await store.list(directory) }
    public func stat(_ path: FilePath) async throws -> FileItem { try await store.stat(path) }

    public func reader(for path: FilePath, from offset: Int64) async throws -> any FileReader {
        if offset > 0, !capabilities.contains(.readAtOffset) { throw FileSourceError.unsupported("resume a read") }
        guard let data = await store.files[path] else {
            throw await store.directories.contains(path) ? FileSourceError.isADirectory(path) : .notFound(path)
        }
        return MemoryReader(data: data, offset: Int(offset))
    }

    public func writer(for path: FilePath, appendingAt offset: Int64) async throws -> any FileWriter {
        guard capabilities.contains(.writable) else { throw FileSourceError.readOnly }
        if offset > 0, !capabilities.contains(.writeAtOffset) { throw FileSourceError.unsupported("resume a write") }
        try await store.prepareWrite(path, offset: offset)
        return MemoryWriter(store: store, path: path)
    }

    public func delete(_ path: FilePath) async throws {
        guard capabilities.contains(.writable) else { throw FileSourceError.readOnly }
        try await store.delete(path)
    }

    public func rename(_ path: FilePath, to newPath: FilePath) async throws {
        guard capabilities.contains(.rename) else { throw FileSourceError.unsupported("rename") }
        try await store.rename(path, to: newPath)
    }

    public func makeDirectory(_ path: FilePath) async throws {
        guard capabilities.contains(.writable) else { throw FileSourceError.readOnly }
        try await store.makeDirectory(path)
    }
}

/// The state behind `MemoryFileSource`.
actor MemoryFileStore {
    var files: [FilePath: Data] = [:]
    var directories: Set<FilePath> = [.root]
    var modified: [FilePath: Date] = [:]

    func seed(_ path: FilePath, _ data: Data, modified date: Date) {
        mkdirs(path.parent)
        files[path] = data
        modified[path] = date
    }

    func mkdirs(_ path: FilePath) {
        for step in path.ancestry { directories.insert(step) }
    }

    func stat(_ path: FilePath) throws -> FileItem {
        if directories.contains(path) { return FileItem(path: path, kind: .directory, modified: modified[path]) }
        guard let data = files[path] else { throw FileSourceError.notFound(path) }
        return FileItem(path: path, kind: .file, size: Int64(data.count), modified: modified[path], permissions: 0o644)
    }

    func list(_ directory: FilePath) throws -> [FileItem] {
        guard directories.contains(directory) else {
            throw files[directory] == nil ? FileSourceError.notFound(directory) : .notADirectory(directory)
        }
        let children = (Array(files.keys) + directories).filter { !$0.isRoot && $0.parent == directory }
        return try children.sorted().map(stat)
    }

    func prepareWrite(_ path: FilePath, offset: Int64) throws {
        guard directories.contains(path.parent) else { throw FileSourceError.notFound(path.parent) }
        if directories.contains(path) { throw FileSourceError.isADirectory(path) }
        let current = files[path] ?? Data()
        guard offset <= Int64(current.count) else { throw FileSourceError.failed("offset past the end") }
        files[path] = current.prefix(Int(offset))
        modified[path] = Date()
    }

    func append(_ data: Data, to path: FilePath) {
        files[path, default: Data()].append(data)
    }

    func delete(_ path: FilePath) throws {
        if directories.contains(path) {
            guard !path.isRoot else { throw FileSourceError.unsupported("delete the root") }
            let hasChildren = files.keys.contains { $0.parent == path } || directories.contains { $0 != path && $0.parent == path }
            if hasChildren { throw FileSourceError.directoryNotEmpty(path) }
            directories.remove(path)
        } else if files.removeValue(forKey: path) == nil {
            throw FileSourceError.notFound(path)
        }
        modified[path] = nil
    }

    func rename(_ path: FilePath, to newPath: FilePath) throws {
        guard files[newPath] == nil, !directories.contains(newPath) else { throw FileSourceError.alreadyExists(newPath) }
        guard directories.contains(newPath.parent) else { throw FileSourceError.notFound(newPath.parent) }
        if let data = files.removeValue(forKey: path) {
            files[newPath] = data
            modified[newPath] = modified.removeValue(forKey: path)
            return
        }
        guard directories.contains(path), !path.isRoot, !path.contains(newPath) else { throw FileSourceError.notFound(path) }
        directories = Set(directories.map { path.contains($0) ? $0.rebased(from: path, onto: newPath) : $0 })
        files = Dictionary(uniqueKeysWithValues: files.map { (path.contains($0.key) ? $0.key.rebased(from: path, onto: newPath) : $0.key, $0.value) })
    }

    func makeDirectory(_ path: FilePath) throws {
        guard files[path] == nil, !directories.contains(path) else { throw FileSourceError.alreadyExists(path) }
        guard directories.contains(path.parent) else { throw FileSourceError.notFound(path.parent) }
        directories.insert(path)
    }
}

actor MemoryReader: FileReader {
    private let data: Data
    private var offset: Int

    init(data: Data, offset: Int) {
        self.data = data
        self.offset = min(offset, data.count)
    }

    func read(maxLength: Int) -> Data {
        let end = min(offset + maxLength, data.count)
        defer { offset = end }
        return data.subdata(in: data.startIndex + offset ..< data.startIndex + end)
    }

    func close() {}
}

struct MemoryWriter: FileWriter {
    let store: MemoryFileStore
    let path: FilePath

    func write(_ data: Data) async throws { await store.append(data, to: path) }
    func finish() async throws {}
    func abort() async {}
}
