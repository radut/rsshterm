import Crypto
import Foundation
import Observation
import RSSHKit

/// F4 on a remote file: a local copy in a private folder, opened in the user's editor, watched, and uploaded every
/// time it is saved. Before an upload the remote file is checked: if someone changed it since the download, the
/// session stops at `.conflict` and asks (overwrite theirs, or reload theirs and drop the local edit).
@MainActor @Observable
public final class RemoteEditSession: Identifiable {
    public enum State: Equatable, Sendable {
        case watching
        case uploading
        /// The last upload, and when.
        case uploaded(Date)
        /// The remote file changed since it was downloaded; answer with `resolveConflict(overwrite:)`.
        case conflict
        case failed(String)
        case finished
    }

    public let id = UUID()
    public let remotePath: FilePath
    public let sourceID: String
    public let sourceName: String
    /// The local copy the editor opens.
    public let localURL: URL
    public private(set) var state: State = .watching
    public private(set) var uploads = 0

    @ObservationIgnored private let source: any FileSource
    @ObservationIgnored private let folder: URL
    /// What the remote file looked like at the last download or upload (size, modification time).
    @ObservationIgnored private var remoteBaseline: FileItem
    /// Digest of the local copy as last downloaded or uploaded.
    @ObservationIgnored private var uploadedDigest: Data
    @ObservationIgnored private var watcher: Task<Void, Never>?

    private init(remote: FileItem, source: any FileSource, folder: URL, localURL: URL, digest: Data) {
        remotePath = remote.path
        sourceID = source.id
        sourceName = source.displayName
        self.source = source
        self.folder = folder
        self.localURL = localURL
        remoteBaseline = remote
        uploadedDigest = digest
    }

    /// A private temp folder for the copies (0700): $TMPDIR/rsshterm-edit-<user id>.
    public nonisolated static func defaultDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rsshterm-edit-\(getuid())", isDirectory: true)
    }

    /// Downloads `item` into its own folder under `directory` and returns the session (not yet watching).
    public static func start(_ item: FileItem, on source: any FileSource, in directory: URL) async throws -> RemoteEditSession {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let local = folder.appendingPathComponent(item.name)
        do {
            try await download(item.path, from: source, to: local)
            let remote = try await source.stat(item.path)
            return RemoteEditSession(remote: remote, source: source, folder: folder, localURL: local,
                                     digest: try digest(of: local))
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Polls the local copy every `interval` (editors save by rename, so a file watch would lose the file).
    public func startWatching(every interval: Duration = .seconds(1)) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.checkForChanges()
            }
        }
    }

    /// Uploads the local copy when its content changed since the last download or upload.
    public func checkForChanges() async {
        guard state != .uploading, state != .conflict, state != .finished else { return }
        guard let current = try? Self.digest(of: localURL), current != uploadedDigest else { return }
        do {
            let remote = try await source.stat(remotePath)
            if remote.size != remoteBaseline.size || remote.modified != remoteBaseline.modified {
                state = .conflict
                return
            }
        } catch FileSourceError.notFound {
            // Deleted on the server: saving puts it back.
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        await upload(current)
    }

    /// The answer to `.conflict`: overwrite the server's version with the local one, or take the server's version
    /// (the local edit is replaced; the editor reloads it).
    public func resolveConflict(overwrite: Bool) async {
        guard state == .conflict else { return }
        if overwrite {
            guard let current = try? Self.digest(of: localURL) else { return }
            await upload(current)
            return
        }
        do {
            try await Self.download(remotePath, from: source, to: localURL)
            remoteBaseline = try await source.stat(remotePath)
            uploadedDigest = try Self.digest(of: localURL)
            state = .watching
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops watching (after a last check) and deletes the local copy.
    public func finish() async {
        watcher?.cancel()
        watcher = nil
        if state != .conflict { await checkForChanges() }
        try? FileManager.default.removeItem(at: folder)
        state = .finished
    }

    // MARK: private

    private func upload(_ digest: Data) async {
        state = .uploading
        do {
            try await Self.upload(localURL, to: remotePath, on: source)
            remoteBaseline = try await source.stat(remotePath)
            uploadedDigest = digest
            uploads += 1
            state = .uploaded(Date())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func download(_ path: FilePath, from source: any FileSource, to local: URL) async throws {
        let reader = try await source.reader(for: path, from: 0)
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            await reader.close()
            throw FileSourceError.failed("Could not create a local copy of \(path.name).")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            while true {
                let chunk = try await reader.read(maxLength: 256 * 1024)
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
            }
            await reader.close()
        } catch {
            await reader.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        _ = try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: temporary, to: local)
    }

    private static func upload(_ local: URL, to path: FilePath, on source: any FileSource) async throws {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        let writer = try await source.writer(for: path, appendingAt: 0)
        do {
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try await writer.write(chunk)
            }
            try await writer.finish()
        } catch {
            await writer.abort()
            throw error
        }
    }

    static func digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }
}

/// Opens a local file in the user's editor: `xdg-open` on Linux (the desktop's default app for the type), `open -t`
/// on the Mac (the default text editor). Arguments are passed as-is, never through a shell.
public enum EditorLauncher {
    public static func command(for url: URL, platform: Platform = .current) -> (executable: String, arguments: [String]) {
        switch platform {
        case .macOS: ("/usr/bin/open", ["-t", url.path])
        case .linux: ("/usr/bin/xdg-open", [url.path])
        }
    }

    public static func open(_ url: URL, runner: any ProcessRunner = FoundationProcessRunner()) {
        let (executable, arguments) = command(for: url)
        try? runner.launchDetached(executable, arguments)
    }
}
