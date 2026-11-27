import Crypto
import Foundation

/// What the server list shows, without anything that logs in: folder names; each server's name, host, port, user
/// and folder; each screen service's kind and address. No credentials or their labels, no notes or tags, no jump
/// hosts, no pinned host keys. Kept on the device (`ServerListCache`) so the list draws before the vault is unlocked.
public struct ServerListSnapshot: Codable, Equatable, Sendable {
    public struct Folder: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var host: String
        public var port: Int
        public var username: String
        public var groupID: UUID?
        public var ssh: Bool
    }

    /// A VNC / Screen Sharing / RDP screen: a server's service (`serverID`) or one listed on its own.
    public struct Screen: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var kind: RemoteDesktop.Kind
        public var host: String
        public var port: Int
        public var username: String?
        public var groupID: UUID?
        public var serverID: UUID?
    }

    public var folders: [Folder]
    public var servers: [Entry]
    public var screens: [Screen]

    public init(vault: Vault) {
        folders = vault.groups.map { Folder(id: $0.id, name: $0.name) }
        servers = vault.servers.map {
            Entry(id: $0.id, name: $0.name, host: $0.host, port: $0.port, username: $0.username, groupID: $0.groupID,
                  ssh: $0.sshEnabled)
        }
        screens = vault.remoteDesktops.map {
            Screen(id: $0.id, name: $0.name, kind: $0.kind, host: $0.host, port: $0.port, username: $0.username,
                   groupID: $0.groupID, serverID: $0.serverID)
        }
    }

    /// A vault to draw the list from: the same rows, no credentials, no logins, nothing to connect with.
    public var displayVault: Vault {
        let servers = servers.map { entry -> Server in
            var server = Server(id: entry.id, name: entry.name, host: entry.host, port: entry.port,
                                username: entry.username, groupID: entry.groupID)
            server.sshEnabled = entry.ssh
            return server
        }
        let screens = screens.map {
            RemoteDesktop(id: $0.id, name: $0.name, kind: $0.kind, host: $0.host, port: $0.port, username: $0.username,
                          groupID: $0.groupID, transport: .direct, serverID: $0.serverID)
        }
        return Vault(groups: folders.map { ServerGroup(id: $0.id, name: $0.name) }, servers: servers,
                     remoteDesktops: screens)
    }
}

/// Where the cache's key lives: on this device only, never synced or backed up (the app uses the Keychain with
/// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly), so a copied file opens nowhere else.
public protocol ServerListCacheKeyStore: Sendable {
    /// The 256-bit key; nil when there is none and `create` is false.
    func key(create: Bool) throws -> Data?
    func delete() throws
}

/// The `ServerListSnapshot` sealed with AES-256-GCM in one file. Anything wrong (no file, no key, another device's
/// key, a changed byte) reads as "no cache": the list then waits for the vault as before.
public struct ServerListCache: Sendable {
    public static let format = "rssh-server-list-v1"
    public let fileURL: URL
    private let keys: any ServerListCacheKeyStore

    public init(fileURL: URL, keys: any ServerListCacheKeyStore) {
        self.fileURL = fileURL
        self.keys = keys
    }

    public func load() -> ServerListSnapshot? {
        guard let sealed = try? Data(contentsOf: fileURL),
              let raw = try? keys.key(create: false), raw.count == 32,
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: raw), authenticating: Data(Self.format.utf8))
        else { return nil }
        return try? JSONDecoder().decode(ServerListSnapshot.self, from: plain)
    }

    public func save(_ snapshot: ServerListSnapshot) throws {
        guard let raw = try keys.key(create: true), raw.count == 32 else { throw ServerListCacheError.noKey }
        let plain = try JSONEncoder().encode(snapshot)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: raw), authenticating: Data(Self.format.utf8))
        guard let combined = box.combined else { throw ServerListCacheError.noKey }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try combined.write(to: fileURL, options: [.atomic])
    }

    /// Removes the file and its key (lock, sign-out, vault reset, the setting turned off).
    public func wipe() {
        try? FileManager.default.removeItem(at: fileURL)
        try? keys.delete()
    }
}

public enum ServerListCacheError: Error, Equatable {
    case noKey
}
