import Foundation
import RSSHKit
import Testing
@testable import RSSHRemote

/// Against a real OpenSSH server; runs only when RSSH_SFTP_IT_HOST is set (IntegrationTests/run.sh sets it up in
/// docker). The key in RSSH_SFTP_IT_KEY and the password in RSSH_SFTP_IT_PASSWORD both log in as RSSH_SFTP_IT_USER.
struct SFTPITConfig {
    let host: String
    let port: Int
    let user: String
    let key: String
    let password: String

    static let current: SFTPITConfig? = {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["RSSH_SFTP_IT_HOST"], !host.isEmpty, let keyPath = env["RSSH_SFTP_IT_KEY"],
              let key = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return nil }
        return SFTPITConfig(host: host, port: Int(env["RSSH_SFTP_IT_PORT"] ?? "") ?? 22,
                            user: env["RSSH_SFTP_IT_USER"] ?? "tester", key: key,
                            password: env["RSSH_SFTP_IT_PASSWORD"] ?? "")
    }()

    var keySecret: Credential.Kind { .privateKey(pem: key, passphrase: nil) }

    func endpoint(_ secrets: [Credential.Kind], known: [KnownHost] = [], host: String? = nil, port: Int? = nil) -> SSHEndpoint {
        SSHEndpoint(host: host ?? self.host, port: port ?? self.port, username: user, secrets: secrets, knownHosts: known)
    }
}

@Suite(.serialized, .enabled(if: SFTPITConfig.current != nil, "set RSSH_SFTP_IT_HOST (IntegrationTests/run.sh)"))
struct SFTPIntegrationTests {
    let it = SFTPITConfig.current!
    let connector = SSHConnector()

    /// The error opening `route` fails with, or nil when it connects (the connection is closed again).
    func failure(_ route: SSHRoute) async -> RemoteConnectError? {
        do {
            let connection = try await connector.connect(route)
            await connection.close()
            return nil
        } catch {
            return error
        }
    }

    /// Connects once without pins to learn the host key (as the trust prompt would), then returns it.
    func pinnedKey(host: String? = nil, port: Int? = nil, jumps: [SSHEndpoint] = []) async throws -> KnownHost {
        let route = SSHRoute(jumps: jumps, target: it.endpoint([it.keySecret], host: host, port: port))
        guard case .unknownHostKey(let key, let hop)? = await failure(route) else {
            Issue.record("expected an unknown host key")
            throw CancellationError()
        }
        #expect(hop == jumps.count)
        return key
    }

    @Test func unknownHostKeyStopsThenPinnedKeyConnectsAndFilesWork() async throws {
        let key = try await pinnedKey()
        let source = try await connector.openSFTP(SSHRoute(target: it.endpoint([it.keySecret], known: [key])),
                                                  id: "it", displayName: "it")
        defer { Task { await source.close() } }
        #expect(source.home.string == "/home/\(it.user)")

        let dir = source.home.appending("rssh-it-\(UUID().uuidString.prefix(8))")
        try await source.makeDirectory(dir)
        let file = dir.appending("hello.txt")
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        try await source.writeAll(body, to: file)
        #expect(try await source.readAll(file) == body)
        #expect(try await source.stat(file).size == Int64(body.count))
        #expect(try await source.list(dir).map(\.name) == ["hello.txt"])

        let renamed = dir.appending("renamed.bin")
        try await source.rename(file, to: renamed)
        #expect(try await source.statIfExists(file) == nil)
        await #expect(throws: FileSourceError.notFound(dir.appending("missing"))) {
            try await source.stat(dir.appending("missing"))
        }

        // Local -> SFTP and back through the transfer engine, as the commander does.
        let localRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let local = LocalFileSource(rootURL: localRoot, displayName: "Local")
        try await local.writeAll(Data("from local\n".utf8), to: FilePath("/up.txt"))
        let engine = TransferEngine()
        let up = await engine.enqueue(TransferRequest(source: local, items: [FilePath("/up.txt")], destination: source,
                                                      destinationDirectory: dir, operation: .copy))
        #expect(await engine.waitUntilFinished(up)?.state == .completed)
        #expect(try await source.readAll(dir.appending("up.txt")) == Data("from local\n".utf8))
        let down = await engine.enqueue(TransferRequest(source: source, items: [renamed], destination: local,
                                                        destinationDirectory: .root, operation: .move))
        #expect(await engine.waitUntilFinished(down)?.state == .completed)
        #expect(try await local.readAll(FilePath("/renamed.bin")) == body)
        #expect(try await source.statIfExists(renamed) == nil)

        try await source.deleteRecursively(try await source.stat(dir))
        #expect(try await source.statIfExists(dir) == nil)
    }

    @Test func changedHostKeyIsRefused() async throws {
        let key = try await pinnedKey()
        let wrong = KnownHost(host: key.host, port: key.port, keyType: key.keyType, fingerprint: "SHA256:not-this-one")
        guard case .changedHostKey(let expected, let presented, _)? =
                await failure(SSHRoute(target: it.endpoint([it.keySecret], known: [wrong]))) else {
            Issue.record("expected a changed host key")
            return
        }
        #expect(expected == wrong && presented.fingerprint == key.fingerprint)
    }

    @Test func vaultKeysAreTriedAfterARefusedOne() async throws {
        let key = try await pinnedKey()
        // The first key is not authorized on the server; the agent's next key is.
        let refused = Credential.Kind.privateKey(pem: TestKeys.ed25519, passphrase: nil)
        let chained = await failure(SSHRoute(target: it.endpoint([refused, it.keySecret], known: [key])))
        #expect(chained == nil, "\(String(describing: chained))")
        #expect(await failure(SSHRoute(target: it.endpoint([refused], known: [key]))) == .failed(.authenticationFailed, hop: 0))
    }

    @Test func passwordLogin() async throws {
        let key = try await pinnedKey()
        #expect(await failure(SSHRoute(target: it.endpoint([.password(it.password)], known: [key]))) == nil)
    }

    @Test func throughAJumpHost() async throws {
        let jumpKey = try await pinnedKey()
        let jump = it.endpoint([it.keySecret], known: [jumpKey])
        // The target is the same server seen from itself: 127.0.0.1:22 through the jump host's direct-tcpip.
        let targetKey = try await pinnedKey(host: "127.0.0.1", port: 22, jumps: [jump])
        let route = SSHRoute(jumps: [jump], target: it.endpoint([it.keySecret], known: [targetKey], host: "127.0.0.1", port: 22))
        let source = try await connector.openSFTP(route, id: "jump", displayName: "via jump")
        #expect(!(try await source.list(source.home)).contains { $0.name == "." })
        await source.close()
    }
}
