@preconcurrency import Citadel
import Foundation
import NIOCore
import RSSHKit
import Synchronization

/// An SFTP server as a file source, on an SSH connection that is either a running session's (shared) or one opened
/// for files (`owned`, closed with `close()`). This is the app's one SFTP helper: the session's `RemoteFileAccess`
/// (uploads, the in-session file sheet) and the Files tab all go through it.
public final class SFTPFileSource: FileSource {
    public let id: String
    public let displayName: String
    public let home: FilePath
    public let capabilities: FileCapabilities = .all
    private let sftp: SFTPClient
    /// Closed with the source, last hop first (a jump chain: target, ..., first jump host).
    private let owned: [ClientBox]

    /// `SSHClient` is not marked Sendable; Citadel serialises its work on the client's event loop.
    public struct ClientBox: @unchecked Sendable {
        public let client: SSHClient
        public init(client: SSHClient) { self.client = client }
    }

    /// Bytes per SFTP read request: servers cap reads (OpenSSH at 256 KiB) and Citadel ignores larger lengths.
    public static let readSize = 64 * 1024
    /// Bytes per SFTP write request (OpenSSH accepts up to 256 KiB).
    public static let writeSize = 64 * 1024

    private init(id: String, displayName: String, home: FilePath, sftp: SFTPClient, owned: [SSHClient]) {
        self.id = id
        self.displayName = displayName
        self.home = home
        self.sftp = sftp
        self.owned = owned.map(ClientBox.init)
    }

    /// Opens an SFTP channel on `client`. `owns` closes the client with the source.
    public static func open(on client: SSHClient, id: String, displayName: String, owns: Bool) async throws -> SFTPFileSource {
        let sftp = try await client.openSFTP()
        let home = (try? await sftp.getRealPath(atPath: ".")).map(FilePath.init) ?? .root
        return SFTPFileSource(id: id, displayName: displayName, home: home, sftp: sftp, owned: owns ? [client] : [])
    }

    /// Opens an SFTP channel on the target of `connection` and owns the whole connection (jump hosts included):
    /// `close()` closes it. On failure the connection is closed too.
    public static func open(over connection: SSHConnection, id: String, displayName: String) async throws -> SFTPFileSource {
        do {
            let sftp = try await connection.target.openSFTP()
            let home = (try? await sftp.getRealPath(atPath: ".")).map(FilePath.init) ?? .root
            return SFTPFileSource(id: id, displayName: displayName, home: home, sftp: sftp,
                                  owned: connection.clientsTargetFirst)
        } catch {
            await connection.close()
            throw error
        }
    }

    /// False once the SFTP channel (or its connection) has closed.
    public var isActive: Bool { sftp.isActive }

    public func close() async {
        try? await sftp.close()
        for box in owned { try? await box.client.close() }
    }

    // MARK: FileSource

    public func list(_ directory: FilePath) async throws -> [FileItem] {
        let names = try await mapped(directory) { try await sftp.listDirectory(atPath: directory.string) }
        return names.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." && !$0.filename.contains("/") }
            .map { Self.item(directory.appending($0.filename), $0.attributes) }
            .sorted { $0.path < $1.path }
    }

    public func stat(_ path: FilePath) async throws -> FileItem {
        Self.item(path, try await mapped(path) { try await sftp.getAttributes(at: path.string) })
    }

    public func reader(for path: FilePath, from offset: Int64) async throws -> any FileReader {
        let file = try await mapped(path) { try await sftp.openFile(filePath: path.string, flags: .read) }
        return SFTPReader(file: file, offset: UInt64(max(0, offset)))
    }

    public func writer(for path: FilePath, appendingAt offset: Int64) async throws -> any FileWriter {
        let flags: SFTPOpenFileFlags = offset > 0 ? [.write, .create] : [.write, .create, .truncate]
        let file = try await mapped(path) { try await sftp.openFile(filePath: path.string, flags: flags) }
        return SFTPWriter(file: file, offset: UInt64(max(0, offset)))
    }

    public func delete(_ path: FilePath) async throws {
        let item = try await stat(path)
        try await mapped(path) {
            if item.isDirectory { try await sftp.rmdir(at: path.string) } else { try await sftp.remove(at: path.string) }
        }
    }

    public func rename(_ path: FilePath, to newPath: FilePath) async throws {
        // SFTP v3 rename fails when the target exists, which is what the engine expects.
        try await mapped(path) { try await sftp.rename(at: path.string, to: newPath.string) }
    }

    public func makeDirectory(_ path: FilePath) async throws {
        if try await statIfExists(path) != nil { throw FileSourceError.alreadyExists(path) }
        try await mapped(path) { try await sftp.createDirectory(atPath: path.string) }
    }

    // MARK: mapping

    public static func item(_ path: FilePath, _ attributes: SFTPFileAttributes) -> FileItem {
        let mode = attributes.permissions
        let kind: FileItem.Kind = switch (mode ?? 0) & 0o170000 {
        case 0o040000: .directory
        case 0o100000: .file
        case 0o120000: .symlink
        default: mode == nil ? .file : .other
        }
        return FileItem(path: path, kind: kind, size: kind == .directory ? nil : attributes.size.map(Int64.init),
                        modified: attributes.accessModificationTime?.modificationTime,
                        permissions: mode.map { $0 & 0o7777 })
    }

    /// SFTP status codes as `FileSourceError`, so the engine can tell "not there" from a real failure.
    private func mapped<T>(_ path: FilePath, _ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch {
            throw Self.translate(error, path: path)
        }
    }

    public static func translate(_ error: any Error, path: FilePath) -> any Error {
        let status: SFTPMessage.Status? = switch error {
        case let status as SFTPMessage.Status: status
        case SFTPError.errorStatus(let status): status
        default: nil
        }
        guard let status else { return error }
        switch status.errorCode {
        case .noSuchFile: return FileSourceError.notFound(path)
        case .permissionDenied: return FileSourceError.failed("Permission denied: \(path.string)")
        default: return FileSourceError.failed(status.message.isEmpty ? "The server refused: \(path.name)" : status.message)
        }
    }
}

/// One open remote file, read front to back. Used by one transfer at a time, so the offset needs no more than a lock.
public final class SFTPReader: FileReader, @unchecked Sendable {
    private let file: SFTPFile
    private let offset: Mutex<UInt64>

    init(file: SFTPFile, offset: UInt64) {
        self.file = file
        self.offset = Mutex(offset)
    }

    public func read(maxLength: Int) async throws -> Data {
        let start = offset.withLock { $0 }
        var buffer = try await file.read(from: start, length: UInt32(min(maxLength, SFTPFileSource.readSize)))
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        offset.withLock { $0 = start + UInt64(bytes.count) }
        return Data(bytes)
    }

    public func close() async { try? await file.close() }
}

public final class SFTPWriter: FileWriter, @unchecked Sendable {
    private let file: SFTPFile
    private let offset: Mutex<UInt64>

    init(file: SFTPFile, offset: UInt64) {
        self.file = file
        self.offset = Mutex(offset)
    }

    public func write(_ data: Data) async throws {
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(start + SFTPFileSource.writeSize, data.endIndex)
            let at = offset.withLock { $0 }
            try await file.write(ByteBuffer(bytes: data[start..<end]), at: at)
            offset.withLock { $0 = at + UInt64(end - start) }
            start = end
        }
    }

    public func finish() async throws { try await file.close() }
    public func abort() async { try? await file.close() }
}
