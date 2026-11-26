import Foundation
import Observation
import RSSHKit
import RSSHRemote

/// Where a file pane points: this computer, a saved server over SFTP (through its jump chain), an open terminal
/// tab's connection, or any other source the app registers (S3 later).
public enum FilePlace: Hashable, Sendable, Identifiable {
    case local
    case server(UUID)
    /// A source the app registered with `FilePlaces.register(_:for:)` (a terminal tab's SFTP, S3, tests).
    case custom(String)

    public var id: String {
        switch self {
        case .local: "local"
        case .server(let id): "sftp:\(id.uuidString.lowercased())"
        case .custom(let key): "custom:\(key)"
        }
    }
}

/// Why a place did not open.
public enum PlaceOpenError: Error, Equatable, Sendable, LocalizedError {
    /// The server's host key is not pinned yet: ask, then `FilePlaces.trust(_:)` and open again.
    case unknownHostKey(KnownHost)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownHostKey(let key): "\(key.host) presented a host key that is not trusted yet: \(key.fingerprint)"
        case .failed(let message): message
        }
    }
}

/// The file manager's places and open sources: one source per place, shared by every pane that shows it (so a move
/// within one server is a rename), the local disk, SFTP for each vault server, and the transfer queue.
@MainActor @Observable
public final class FilePlaces {
    public typealias Opener = @Sendable (_ server: Server, _ vault: Vault) async throws -> any FileSource

    public let transfers: TransferCenter
    /// Offer the vault's other keys (the built-in agent's) after the server's own login, as `ssh` would.
    public var useAgentKeys = true
    @ObservationIgnored public let document: any VaultDocument
    @ObservationIgnored private var open: [FilePlace: any FileSource] = [:]
    @ObservationIgnored private var custom: [String: (title: String, source: any FileSource)] = [:]
    @ObservationIgnored private let local: any FileSource
    @ObservationIgnored private let opener: Opener?

    /// `local` defaults to the whole disk with the home folder as start; `opener` replaces SFTP (tests).
    public init(document: any VaultDocument, local: (any FileSource)? = nil, opener: Opener? = nil,
                transfers: TransferCenter = TransferCenter()) {
        self.document = document
        self.local = local ?? LocalDisk.source()
        self.opener = opener
        self.transfers = transfers
    }

    /// The place picker's entries: this computer, the registered ones, then every saved server.
    public var places: [FilePlace] {
        [.local] + custom.keys.sorted().map(FilePlace.custom) + document.vault.servers.map { .server($0.id) }
    }

    public func title(of place: FilePlace) -> String {
        switch place {
        case .local: "This Computer"
        case .server(let id): document.vault.servers.first { $0.id == id }?.name ?? "Server"
        case .custom(let key): custom[key]?.title ?? key
        }
    }

    /// Makes `source` a place (a terminal tab's SFTP on its own connection, S3, ...).
    public func register(_ source: any FileSource, title: String, for key: String) {
        custom[key] = (title, source)
        open[.custom(key)] = source
    }

    public func unregister(_ key: String) {
        custom[key] = nil
        open[.custom(key)] = nil
    }

    /// The open source of `place`, connecting the first time.
    public func source(for place: FilePlace) async throws(PlaceOpenError) -> any FileSource {
        if let source = open[place], (source as? SFTPFileSource)?.isActive ?? true { return source }
        switch place {
        case .local:
            return local
        case .custom(let key):
            guard let source = custom[key]?.source else { throw .failed("That place is no longer open.") }
            return source
        case .server(let id):
            let vault = document.vault
            guard let server = vault.servers.first(where: { $0.id == id }) else {
                throw .failed(VaultEdits.errorMessage(.unknownServer))
            }
            let source = try await connect(server, vault)
            open[place] = source
            return source
        }
    }

    /// Forgets an open source (its connection dropped); the next `source(for:)` connects again.
    public func forget(_ place: FilePlace) {
        if let sftp = open[place] as? SFTPFileSource { Task { await sftp.close() } }
        open[place] = nil
    }

    /// Pins a host key in the vault (the pane's "Trust" answer).
    public func trust(_ key: KnownHost) async throws {
        guard let pinned = HostKeyPolicy.pinning(key.trusted(at: Date()), in: document.vault.knownHosts) else { return }
        var vault = document.vault
        vault.knownHosts = pinned
        try await document.commit(vault)
    }

    public func closeAll() async {
        for source in open.values { await (source as? SFTPFileSource)?.close() }
        open = [:]
    }

    private func connect(_ server: Server, _ vault: Vault) async throws(PlaceOpenError) -> any FileSource {
        do {
            if let opener { return try await opener(server, vault) }
            let route: SSHRoute
            do { route = try SSHRoute.resolve(server, in: vault, agentKeys: useAgentKeys) } catch {
                throw PlaceOpenError.failed(error.message)
            }
            return try await SSHConnector().openSFTP(route, id: FilePlace.server(server.id).id, displayName: server.name)
        } catch let error as RemoteConnectError {
            if case .unknownHostKey(let key, _) = error { throw .unknownHostKey(key) }
            let message = error.errorDescription ?? "The connection failed."
            // Name the jump host that failed, as the terminal does.
            let hops = (try? vault.connectionHops(to: server)) ?? []
            if error.hop < hops.count - 1 { throw .failed("Via \(hops[error.hop].name): \(message)") }
            throw .failed(message)
        } catch let error as PlaceOpenError {
            throw error
        } catch {
            throw .failed(RemoteErrorMapper.failure(for: error, host: server.host).message)
        }
    }
}

/// The local disk as a file source: "/" is the root, browsing starts in the home folder.
public enum LocalDisk {
    public static func source(home: String = NSHomeDirectory()) -> any FileSource {
        HomeStartingSource(base: LocalFileSource(rootURL: URL(fileURLWithPath: "/"), displayName: "This Computer",
                                                 id: "local"),
                           home: FilePath(home))
    }

    /// The local path of `path` on the disk source (drag out, open in an editor).
    public static func url(for path: FilePath) -> URL { URL(fileURLWithPath: path.string) }
}

/// A source that starts browsing at `home` instead of the base's own home.
struct HomeStartingSource: FileSource {
    let base: any FileSource
    let home: FilePath

    var id: String { base.id }
    var displayName: String { base.displayName }
    var capabilities: FileCapabilities { base.capabilities }
    func list(_ directory: FilePath) async throws -> [FileItem] { try await base.list(directory) }
    func stat(_ path: FilePath) async throws -> FileItem { try await base.stat(path) }
    func reader(for path: FilePath, from offset: Int64) async throws -> any FileReader { try await base.reader(for: path, from: offset) }
    func writer(for path: FilePath, appendingAt offset: Int64) async throws -> any FileWriter {
        try await base.writer(for: path, appendingAt: offset)
    }
    func delete(_ path: FilePath) async throws { try await base.delete(path) }
    func rename(_ path: FilePath, to newPath: FilePath) async throws { try await base.rename(path, to: newPath) }
    func makeDirectory(_ path: FilePath) async throws { try await base.makeDirectory(path) }
}
