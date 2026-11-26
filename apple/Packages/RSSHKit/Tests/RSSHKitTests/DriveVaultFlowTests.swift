import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RSSHKit

/// A tiny Drive v3 for one appDataFolder: files.list, alt=media download, multipart create, media PATCH; `version`
/// grows by one with every write, as Drive's does.
actor FakeDrive: HTTPTransport {
    private var files: [String: (name: String, data: Data, version: Int)] = [:]
    private var nextID = 1
    private(set) var tokens: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        let url = try #require(request.url)
        let path = url.path
        func reply(_ status: Int, _ body: Data) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func meta(_ id: String) -> Data {
            Data(#"{"id":"\#(id)","version":"\#(files[id]!.version)"}"#.utf8)
        }
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/drive/v3/files"):
            let list = files.keys.sorted().map { #"{"id":"\#($0)","version":"\#(files[$0]!.version)"}"# }
            return reply(200, Data(#"{"files":[\#(list.joined(separator: ","))]}"#.utf8))
        case ("GET", let p) where p.hasPrefix("/drive/v3/files/"):
            guard let file = files[String(p.dropFirst("/drive/v3/files/".count))] else { return reply(404, Data()) }
            return reply(200, file.data)
        case ("POST", "/upload/drive/v3/files"):
            let body = try #require(request.httpBody)
            let boundary = try #require(request.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last)
            let start = try #require(body.range(of: Data("application/octet-stream\r\n\r\n".utf8))).upperBound
            let end = try #require(body.range(of: Data("\r\n--\(boundary)--".utf8))).lowerBound
            let content = body.subdata(in: start..<end)
            let id = "F\(nextID)"
            nextID += 1
            files[id] = (GoogleDriveVaultStore.fileName, content, 1)
            return reply(200, meta(id))
        case ("PATCH", let p) where p.hasPrefix("/upload/drive/v3/files/"):
            let id = String(p.dropFirst("/upload/drive/v3/files/".count))
            guard let old = files[id] else { return reply(404, Data()) }
            files[id] = (old.name, try #require(request.httpBody), old.version + 1)
            return reply(200, meta(id))
        default:
            return reply(400, Data())
        }
    }
}

/// Two devices that share only a Google Drive and a master password.
@Suite struct DriveVaultFlowTests {
    static let fast = MasterPasswordKDF.scrypt(logN: 10, blockSize: 8, parallelism: 1)
    static let password = "correct horse battery"

    struct Device {
        let keys: MemoryDeviceKeyStore
        let drive: GoogleDriveVaultStore
        let name: String

        init(_ name: String, drive: FakeDrive) {
            self.name = name
            keys = MemoryDeviceKeyStore(requiresUserPresence: name == "mac")
            self.drive = GoogleDriveVaultStore(transport: drive, accessToken: { "token-\(name)" })
        }

        func wrapper() async throws -> DeviceKeyWrapper { try await keys.loadOrCreate().wrapper() }

        func load() async throws -> (VaultEnvelope, String) {
            let stored = try #require(try await drive.load())
            return (try JSONDecoder().decode(VaultEnvelope.self, from: stored.data), stored.revision)
        }

        func save(_ envelope: VaultEnvelope, ifMatch: String?) async throws -> String {
            try await drive.save(try JSONEncoder().encode(envelope), ifMatch: ifMatch)
        }
    }

    @Test func newDeviceJoinsWithTheMasterPasswordAndConflictsAreCaught() async throws {
        let cloud = FakeDrive()
        let linux = Device("linux", drive: cloud), mac = Device("mac", drive: cloud)

        // 1. The first device makes the vault: its own key plus the master password.
        var vault = Vault()
        vault.servers = [Server(name: "alpha", host: "alpha.example", username: "ops")]
        let first = try await VaultCipher.makeEnvelope(
            vault, key: VaultCipher.newVaultKey(),
            wrappers: [try await linux.wrapper(), try MasterPasswordKeyWrapper(password: Self.password, kdf: Self.fast)],
            metadata: VaultMetadata(revision: 1, updatedAt: Date(), deviceName: "linux"))
        #expect(try await linux.save(first, ifMatch: nil) == "1")

        // 2. The Mac has no key that opens it: it asks for the master password, then adds its own key on save.
        let (seen, rev1) = try await mac.load()
        guard case .needsMasterPassword = try await VaultOpener.open(seen, wrappers: [try await mac.wrapper()]) else {
            Issue.record("the Mac was not asked for the master password")
            return
        }
        let byPassword = try await VaultOpener.open(seen, masterPassword: Self.password, device: try await mac.wrapper())
        var macEdit = byPassword.vault
        macEdit.servers.append(Server(name: "beta", host: "beta.example", username: "ops"))
        let macEnvelope = try await VaultOpener.nextEnvelope(macEdit, after: byPassword, wrappers: [], deviceName: "mac",
                                                             now: Date())
        #expect(try await mac.save(macEnvelope, ifMatch: rev1) == "2")

        // 3. Linux still holds revision 1: its save is refused instead of overwriting the Mac's edit.
        guard case .opened(let linuxStale) = try await VaultOpener.open(first, wrappers: [try await linux.wrapper()]) else {
            Issue.record("linux could not open its own vault")
            return
        }
        let stale = try await VaultOpener.nextEnvelope(linuxStale.vault, after: linuxStale, wrappers: [try await linux.wrapper()],
                                                       deviceName: "linux", now: Date())
        await #expect(throws: VaultStoreError.conflict(currentRevision: "2")) { try await linux.save(stale, ifMatch: "1") }

        // 4. Linux reloads: its own key still opens it (the Mac carried the entry over) and it sees "beta".
        let (latest, rev2) = try await linux.load()
        guard case .opened(let linuxNow) = try await VaultOpener.open(latest, wrappers: [try await linux.wrapper()]) else {
            Issue.record("linux lost its entry")
            return
        }
        #expect(linuxNow.vault.servers.map(\.name) == ["alpha", "beta"])
        let next = try await VaultOpener.nextEnvelope(linuxNow.vault, after: linuxNow, wrappers: [try await linux.wrapper()],
                                                      deviceName: "linux", now: Date())
        #expect(try await linux.save(next, ifMatch: rev2) == "3")

        // 5. From now on the Mac opens it with its own key, no password.
        let (third, _) = try await mac.load()
        guard case .opened(let macNow) = try await VaultOpener.open(third, wrappers: [try await mac.wrapper()]) else {
            Issue.record("the Mac still needs the password")
            return
        }
        #expect(macNow.vault.servers.count == 2)
        #expect(third.revision == 3)
        #expect(third.deviceName == "linux")
        #expect(await cloud.tokens.contains("Bearer token-mac"))
    }
}
