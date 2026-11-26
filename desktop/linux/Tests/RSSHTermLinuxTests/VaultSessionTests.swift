import Foundation
import RSSHKit
import Testing
@testable import RSSHTermLinux

/// The unlock flow on a real file store, with a fast scrypt so the suite stays quick.
@Suite struct VaultSessionTests {
    static let fastKDF = MasterPasswordKDF.scrypt(logN: 10, blockSize: 8, parallelism: 1)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    var file: URL { dir.appendingPathComponent("vault.json") }

    private func session(keys: MemoryDeviceKeyStore) -> VaultSession {
        VaultSession(store: LocalFileVaultStore(fileURL: file), deviceKeys: keys, deviceName: "test-box",
                     kdf: Self.fastKDF, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private func sample() -> Vault {
        let cred = Credential(label: "k", kind: .password("p"))
        return Vault(servers: [Server(name: "web", host: "web.example.com", username: "u", credentialID: cred.id)],
                     credentials: [cred])
    }

    @Test func emptyStoreAsksToCreate() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await session(keys: MemoryDeviceKeyStore()).load() == .noVault)
    }

    @Test func createThenReopenWithTheDeviceKey() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryDeviceKeyStore()
        let created = try await session(keys: keys).create(masterPassword: "correct horse", vault: sample())
        #expect(created.servers.count == 1)
        let again = try await session(keys: keys).load()
        guard case .opened(let vault) = again else { Issue.record("expected opened, got \(again)"); return }
        #expect(vault == created)
    }

    @Test func shortMasterPasswordIsRefused() async {
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: VaultSessionError.passwordTooShort) {
            _ = try await session(keys: MemoryDeviceKeyStore()).create(masterPassword: "short", vault: Vault())
        }
    }

    @Test func newDeviceNeedsTheMasterPasswordOnceThenNot() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await session(keys: MemoryDeviceKeyStore()).create(masterPassword: "correct horse", vault: sample())

        let newDevice = MemoryDeviceKeyStore()
        let first = session(keys: newDevice)
        #expect(try await first.load() == .needsMasterPassword)
        await #expect(throws: VaultSessionError.wrongPassword) { _ = try await first.unlock(masterPassword: "nope nope") }
        let vault = try await first.unlock(masterPassword: "correct horse")
        #expect(vault.servers.first?.name == "web")

        // The unlock saved an envelope with this device's key: no password next time.
        guard case .opened = try await session(keys: newDevice).load() else { Issue.record("device key not added"); return }
    }

    @Test func verifyMasterPasswordForReauth() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryDeviceKeyStore()
        let s = session(keys: keys)
        _ = try await s.create(masterPassword: "correct horse", vault: sample())
        #expect(try await s.verify(masterPassword: "correct horse"))
        #expect(try await !s.verify(masterPassword: "wrong one!"))
        #expect(await s.hasMasterPassword)
    }

    @Test func saveWritesAChangedVault() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryDeviceKeyStore()
        let s = session(keys: keys)
        var vault = try await s.create(masterPassword: "correct horse", vault: sample())
        vault.servers.append(Server(name: "db", host: "db.example.com", username: "pg"))
        try await s.save(vault)
        guard case .opened(let reread) = try await session(keys: keys).load() else { Issue.record("reopen"); return }
        #expect(reread.servers.map(\.name) == ["web", "db"])
    }

    @Test func importPlainVaultJSON() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = try JSONEncoder().encode(sample())
        let vault = try VaultSession.decodePlain(json)
        #expect(vault.servers.first?.host == "web.example.com")
        #expect(throws: VaultSessionError.self) { _ = try VaultSession.decodePlain(Data("[]".utf8)) }
    }
}
