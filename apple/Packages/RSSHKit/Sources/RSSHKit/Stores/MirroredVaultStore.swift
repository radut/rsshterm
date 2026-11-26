import Foundation

/// The local file plus a second copy that outlives it (the app's Keychain item, which survives deleting and
/// reinstalling the app while Application Support does not). Reads take the newer of the two by envelope revision and
/// repair the other; writes go to the file (conditionally, as before) and then to the copy.
public struct MirroredVaultStore: VaultStore {
    public let primary: any VaultStore
    public let mirror: any VaultStore

    public init(primary: any VaultStore, mirror: any VaultStore) {
        self.primary = primary
        self.mirror = mirror
    }

    public var id: String { primary.id }
    public var displayName: String { primary.displayName }

    public func load() async throws -> StoredVault? {
        let file = try await primary.load()
        // The copy is a safety net: if the Keychain cannot be read, the file still works.
        let copy = try? await mirror.load()
        switch (file, copy) {
        case (nil, nil):
            return nil
        case (let file?, nil):
            await writeMirror(file.data, over: nil)
            return file
        case (nil, let copy?):
            return try await restore(copy.data, over: nil)
        case (let file?, let copy?):
            if file.data == copy.data { return file }
            if Self.revision(of: copy.data) > Self.revision(of: file.data) {
                return try await restore(copy.data, over: file.revision)
            }
            await writeMirror(file.data, over: copy)
            return file
        }
    }

    public func save(_ data: Data, ifMatch revision: String?) async throws -> String {
        let saved = try await primary.save(data, ifMatch: revision)
        await writeMirror(data, over: try? await mirror.load())
        return saved
    }

    /// The copy follows the file unconditionally; a failure leaves the file as the one source of truth.
    private func writeMirror(_ data: Data, over current: StoredVault?) async {
        _ = try? await mirror.save(data, ifMatch: current?.revision)
    }

    private func restore(_ data: Data, over revision: String?) async throws -> StoredVault {
        let saved = try await primary.save(data, ifMatch: revision)
        return StoredVault(data: data, revision: saved)
    }

    /// The envelope's revision; 0 for anything unreadable or without one, so a readable copy wins over it.
    static func revision(of data: Data) -> UInt64 {
        (try? JSONDecoder().decode(VaultEnvelope.self, from: data))?.revision ?? 0
    }
}
