import Crypto
import Foundation
import Testing
@testable import RSSHKit

/// The server list kept on this device so it shows before the vault is unlocked: only what the rows show, sealed
/// with a device-only key, gone with that key.
@Suite struct ServerListCacheTests {
    static let secretPassword = "hunter2-very-secret"
    static let secretNote = "root password is on the sticky note"

    /// A vault with every kind of secret next to the list fields.
    static func vault() -> Vault {
        let home = ServerGroup(name: "Home")
        let password = Credential(label: "admin password label", kind: .password(secretPassword))
        let key = Credential(label: "laptop key label", kind: .privateKey(
            pem: OpenSSHPrivateKey.encode(Ed25519KeyPair.generate(comment: "cache-test")), passphrase: "key-passphrase"))
        var nas = Server(name: "NAS", host: "192.0.2.10", port: 2222, username: "admin", credentialID: password.id,
                         groupID: home.id)
        nas.notes = secretNote
        nas.tags = ["tag-private"]
        nas.jumpHosts = [.inline(InlineJumpHost(host: "bastion.example.com", username: "jump", credentialID: key.id))]
        let router = Server(name: "Router", host: "192.0.2.1", username: "root", credentialID: key.id)
        let vnc = RemoteDesktop(name: "NAS", kind: .vnc, host: "localhost", credentialID: password.id,
                                groupID: home.id, tunnelServerID: nas.id, serverID: nas.id)
        let lone = RemoteDesktop(name: "Office PC", kind: .rdp, host: "198.51.100.5", username: "office",
                                 credentialID: password.id, domain: "CORP")
        let known = KnownHost(host: "192.0.2.10", port: 2222, keyType: "ssh-ed25519", fingerprint: "pinned-host-key")
        return Vault(groups: [home], servers: [nas, router], credentials: [password, key], knownHosts: [known],
                     remoteDesktops: [vnc, lone])
    }

    func makeCache(keys: MemoryCacheKeys = MemoryCacheKeys()) -> (ServerListCache, URL, MemoryCacheKeys) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-list-\(UUID().uuidString)")
        return (ServerListCache(fileURL: dir.appendingPathComponent("server-list.sealed"), keys: keys), dir, keys)
    }

    @Test func snapshotKeepsOnlyWhatTheRowsShow() {
        let vault = Self.vault()
        let snapshot = ServerListSnapshot(vault: vault)
        #expect(snapshot.folders.map(\.name) == ["Home"])
        let nas = snapshot.servers.first { $0.name == "NAS" }
        #expect(nas?.host == "192.0.2.10")
        #expect(nas?.port == 2222)
        #expect(nas?.username == "admin")
        #expect(nas?.groupID == vault.groups[0].id)
        #expect(snapshot.screens.count == 2)
        #expect(snapshot.screens.first { $0.serverID == nas?.id }?.kind == .vnc)
    }

    @Test func displayVaultHasNoSecretsAndNoWayToLogIn() throws {
        let display = ServerListSnapshot(vault: Self.vault()).displayVault
        #expect(display.credentials.isEmpty)
        #expect(display.knownHosts.isEmpty)
        #expect(display.servers.allSatisfy { $0.credentialID == nil && $0.jumpHosts.isEmpty })
        #expect(display.servers.allSatisfy { $0.notes == nil && $0.tags.isEmpty })
        #expect(display.remoteDesktops.allSatisfy { $0.credentialID == nil && $0.domain == nil })
        let text = String(decoding: try JSONEncoder().encode(display), as: UTF8.self)
        for secret in Self.secrets { #expect(!text.contains(secret), "display vault holds \(secret)") }
    }

    @Test func displayVaultListsTheSameRows() {
        let vault = Self.vault()
        let display = ServerListSnapshot(vault: vault).displayVault
        #expect(display.groups == vault.groups)
        #expect(display.servers.map(\.id) == vault.servers.map(\.id))
        let nas = vault.servers[0]
        #expect(display.servers(inGroup: nas.groupID).map(\.name) == ["NAS"])
        #expect(display.services(of: nas.id).map(\.kind) == [.vnc])
        #expect(display.connectChoices(for: display.servers[0]).count == 2)
        #expect(display.standaloneRemoteDesktops.map(\.name) == ["Office PC"])
    }

    @Test func saveThenLoadGivesTheSnapshotBack() throws {
        let (cache, dir, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = ServerListSnapshot(vault: Self.vault())
        try cache.save(snapshot)
        #expect(cache.load() == snapshot)
    }

    @Test func theFileIsSealedAndHoldsNoSecrets() throws {
        let (cache, dir, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(ServerListSnapshot(vault: Self.vault()))
        let bytes = try Data(contentsOf: cache.fileURL)
        let text = String(decoding: bytes, as: UTF8.self)
        for visible in ["NAS", "192.0.2.10", "admin", "Home"] {
            #expect(!text.contains(visible), "the file shows \(visible) in the clear")
        }
        for secret in Self.secrets { #expect(!text.contains(secret)) }
    }

    @Test func nothingSavedLoadsNilAndMakesNoKey() {
        let (cache, dir, keys) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(cache.load() == nil)
        #expect(keys.stored == nil)
    }

    @Test func anotherDevicesKeyCannotReadIt() throws {
        let (cache, dir, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(ServerListSnapshot(vault: Self.vault()))
        // The file restored from a backup onto a device that has a different key (or none).
        let other = ServerListCache(fileURL: cache.fileURL, keys: MemoryCacheKeys())
        #expect(other.load() == nil)
        let stranger = MemoryCacheKeys()
        _ = try stranger.key(create: true)
        #expect(ServerListCache(fileURL: cache.fileURL, keys: stranger).load() == nil)
    }

    @Test func aTamperedFileLoadsNil() throws {
        let (cache, dir, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(ServerListSnapshot(vault: Self.vault()))
        var bytes = try Data(contentsOf: cache.fileURL)
        bytes[bytes.count - 3] ^= 0x01
        try bytes.write(to: cache.fileURL)
        #expect(cache.load() == nil)
    }

    @Test func wipeRemovesTheFileAndTheKey() throws {
        let (cache, dir, keys) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(ServerListSnapshot(vault: Self.vault()))
        cache.wipe()
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL.path))
        #expect(keys.stored == nil)
        #expect(cache.load() == nil)
    }

    @Test func saveReplacesTheOldList() throws {
        let (cache, dir, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(ServerListSnapshot(vault: Self.vault()))
        let smaller = ServerListSnapshot(vault: Vault(servers: [Server(name: "Only", host: "203.0.113.9", username: "u")]))
        try cache.save(smaller)
        #expect(cache.load() == smaller)
    }

    /// Two hundred servers in ten folders seal and open in well under the time a frame takes on a phone.
    @Test func twoHundredServersRoundTrip() throws {
        let (cache, dir, _) = makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = (0..<10).map { ServerGroup(name: "Folder \($0)") }
        let servers = (0..<200).map {
            Server(name: "server-\($0)", host: "192.0.2.\($0 % 250)", username: "user", groupID: groups[$0 % 10].id)
        }
        let snapshot = ServerListSnapshot(vault: Vault(groups: groups, servers: servers))
        try cache.save(snapshot)
        #expect(cache.load()?.displayVault.servers.count == 200)
    }

    static let secrets = [secretPassword, secretNote, "key-passphrase", "admin password label", "laptop key label",
                          "tag-private", "bastion.example.com", "pinned-host-key", "CORP", "OPENSSH PRIVATE KEY"]
}

/// The device-only key in memory (the app keeps it in the Keychain).
final class MemoryCacheKeys: ServerListCacheKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    var stored: Data? { lock.withLock { value } }

    func key(create: Bool) throws -> Data? {
        try lock.withLock {
            if value == nil, create { value = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
            return value
        }
    }

    func delete() throws {
        lock.withLock { value = nil }
    }
}
