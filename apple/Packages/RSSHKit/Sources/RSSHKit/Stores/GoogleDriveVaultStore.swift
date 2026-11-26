import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The vault envelope as `rssh-vault.json` in the app's Google Drive appDataFolder (hidden from the user's Drive,
/// visible only to this OAuth client; scope `drive.appdata`). The revision is Drive's `version`.
///
/// RACE WINDOW: Drive v3 has no conditional update (no If-Match on files.update), so `save` re-reads the file's
/// metadata, compares its version with `ifMatch`, and only then uploads. Another device that writes between that
/// read and the upload is overwritten. The window is one round trip; `VaultSync` narrows the damage because the
/// overwritten device sees a newer version on its next sync and the newest envelope wins again, but an edit made in
/// that window can be lost. Same for create: two devices creating at once make two files; `find` takes the newest.
public struct GoogleDriveVaultStore: VaultStore {
    public static let fileName = "rssh-vault.json"
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    public let id = "google-drive"
    public let displayName = "Google Drive"
    private let transport: any HTTPTransport
    private let accessToken: AccessTokenProvider

    /// `accessToken` is asked before every request, so the sign-in layer can refresh it; its error is passed through.
    public init(transport: any HTTPTransport = URLSessionTransport(), accessToken: @escaping AccessTokenProvider) {
        self.transport = transport
        self.accessToken = accessToken
    }

    public func load() async throws -> StoredVault? {
        guard let file = try await find() else { return nil }
        guard let revision = file.revision else { throw RemoteStoreError.unexpectedResponse("no file version") }
        let (status, data) = try await send(DriveRequests.download(fileID: file.id))
        if status == 404 { return nil }   // deleted between the list and the download
        try Self.check(status, data)
        return StoredVault(data: data, revision: revision)
    }

    public func save(_ data: Data, ifMatch revision: String?) async throws -> String {
        guard let file = try await find() else {
            return try await upload(DriveRequests.create(name: Self.fileName, data: data))
        }
        let current = file.revision ?? ""
        guard current == revision else { throw VaultStoreError.conflict(currentRevision: current) }
        return try await upload(DriveRequests.update(fileID: file.id, data: data))
    }

    private func find() async throws -> DriveFile? {
        let (status, data) = try await send(DriveRequests.find(name: Self.fileName))
        try Self.check(status, data)
        return try Self.decode(DriveFileList.self, data).files.first
    }

    private func upload(_ request: URLRequest) async throws -> String {
        let (status, data) = try await send(request)
        try Self.check(status, data)
        guard let revision = try Self.decode(DriveFile.self, data).revision else {
            throw RemoteStoreError.unexpectedResponse("no file version")
        }
        return revision
    }

    private func send(_ request: URLRequest) async throws -> (Int, Data) {
        var authorized = request
        authorized.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(authorized)
        return (response.statusCode, data)
    }

    static func check(_ status: Int, _ body: Data) throws {
        switch status {
        case 200..<300: return
        case 401: throw RemoteStoreError.unauthorized
        default:
            let message = (try? JSONDecoder().decode(DriveErrorBody.self, from: body))?.error?.message ?? ""
            throw RemoteStoreError.http(status: status, message: message)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw RemoteStoreError.unexpectedResponse(String(describing: type))
        }
    }
}
