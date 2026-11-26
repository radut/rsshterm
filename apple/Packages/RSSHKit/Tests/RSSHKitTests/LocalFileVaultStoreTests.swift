import Foundation
import Testing
@testable import RSSHKit

@Suite struct LocalFileVaultStoreTests {
    /// A fresh directory per test; the file inside does not exist yet.
    func makeStore() -> (LocalFileVaultStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("nested").appendingPathComponent("vault.json")
        return (LocalFileVaultStore(fileURL: url), dir)
    }

    @Test func emptyLoadsNil() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await store.load() == nil)
    }

    @Test func saveThenLoadReturnsContentAndHashRevision() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rev = try await store.save(Data("abc".utf8), ifMatch: nil)
        // SHA-256("abc")
        #expect(rev == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let loaded = try await store.load()
        #expect(loaded == StoredVault(data: Data("abc".utf8), revision: rev))
    }

    @Test func saveWithMatchingRevisionReplaces() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await store.save(Data("one".utf8), ifMatch: nil)
        let second = try await store.save(Data("two".utf8), ifMatch: first)
        #expect(second != first)
        #expect(try await store.load()?.data == Data("two".utf8))
    }

    @Test func saveWithStaleRevisionConflicts() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await store.save(Data("one".utf8), ifMatch: nil)
        _ = try await store.save(Data("two".utf8), ifMatch: first)
        let current = try await store.load()!.revision
        await #expect(throws: VaultStoreError.conflict(currentRevision: current)) {
            try await store.save(Data("three".utf8), ifMatch: first)
        }
        #expect(try await store.load()?.data == Data("two".utf8))
    }

    @Test func saveWithoutRevisionOverExistingFileConflicts() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await store.save(Data("one".utf8), ifMatch: nil)
        await #expect(throws: VaultStoreError.conflict(currentRevision: first)) {
            try await store.save(Data("two".utf8), ifMatch: nil)
        }
    }

    @Test func leavesNoTemporaryFilesBehind() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rev = try await store.save(Data("one".utf8), ifMatch: nil)
        _ = try await store.save(Data("two".utf8), ifMatch: rev)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("nested").path)
        #expect(files == ["vault.json"])
    }

    @Test func defaultLocationIsApplicationSupport() {
        let store = LocalFileVaultStore()
        #expect(store.fileURL.lastPathComponent == LocalFileVaultStore.fileName)
        #expect(store.fileURL.path.contains("Application Support") || store.fileURL.path.contains(".local/share")
            || store.fileURL.path.contains("rSSH"))
        #expect(store.id == "local")
    }
}
