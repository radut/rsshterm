import Crypto
import Foundation

/// The vault envelope as one file on this device (Application Support/rSSH/vault.json by default).
/// The revision is the SHA-256 of the content, so it changes exactly when the bytes do, whoever wrote them.
public actor LocalFileVaultStore: VaultStore {
    public static let fileName = "vault.json"

    public nonisolated let id = "local"
    public nonisolated let displayName = "On this device"
    public nonisolated let fileURL: URL

    public init(fileURL: URL = LocalFileVaultStore.defaultURL()) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("rSSH", isDirectory: true).appendingPathComponent(fileName)
    }

    public func load() async throws -> StoredVault? {
        guard let data = try readIfPresent() else { return nil }
        return StoredVault(data: data, revision: Self.revision(of: data))
    }

    /// Checks `revision` against the file and replaces it atomically (write to a temporary file, then rename), so a
    /// crash never leaves half a vault. The actor serialises saves within the app; another process is not expected.
    public func save(_ data: Data, ifMatch revision: String?) async throws -> String {
        if let current = try readIfPresent() {
            let currentRevision = Self.revision(of: current)
            guard currentRevision == revision else { throw VaultStoreError.conflict(currentRevision: currentRevision) }
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: Self.writeOptions)
        return Self.revision(of: data)
    }

    static func revision(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    private func readIfPresent() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }
}
