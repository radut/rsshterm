import Crypto
import _CryptoExtras
import Foundation
import RSSHKit
import Synchronization
import Testing
@testable import RSSHDesktopCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A client speaking the agent protocol over a real unix socket.
private struct AgentClient {
    let fd: Int32

    init(path: String) throws { fd = try UnixSocket.connect(to: path) }

    func close() { closeDescriptor(fd) }

    func request(_ payload: Data) throws -> Data {
        guard UnixSocket.writeAll(fd, AgentFramer.frame(payload)) else { throw CocoaError(.fileWriteUnknown) }
        var framer = AgentFramer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw CocoaError(.fileReadUnknown) }
            if let message = try framer.append(buffer[0..<n]).first { return message }
        }
    }

    func identities() throws -> [(blob: Data, comment: String)] {
        var reader = WireReader(try request(Data([AgentMessage.requestIdentities])))
        guard try reader.byte() == AgentMessage.identitiesAnswer else { throw CocoaError(.coderReadCorrupt) }
        return try (0..<reader.uint32()).map { _ in (try reader.string(), try reader.text()) }
    }

    /// The signature blob, or nil for SSH_AGENT_FAILURE.
    func sign(blob: Data, data: Data, flags: UInt32 = 0) throws -> (algorithm: String, signature: Data)? {
        let reply = try request(Data([AgentMessage.signRequest]) + wireString(blob) + wireString(data) + wireUInt32(flags))
        var reader = WireReader(reply)
        let type = try reader.byte()
        if type == AgentMessage.failure { return nil }
        guard type == AgentMessage.signResponse else { throw CocoaError(.coderReadCorrupt) }
        var inner = WireReader(try reader.string())
        return (try inner.text(), try inner.string())
    }
}

private struct Fixture {
    let ed25519 = Ed25519KeyPair.generate(comment: "ed-key")
    let p256 = P256.Signing.PrivateKey()
    let rsa: _RSA.Signing.PrivateKey
    let credentials: [Credential]

    init() throws {
        rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let ecPEM = try KeyImport.convert(p256.pemRepresentation, passphrase: nil, comment: "ec-key").pem
        let rsaPEM = try KeyImport.convert(rsa.pemRepresentation, passphrase: nil, comment: "rsa-key").pem
        credentials = [
            Credential(label: "Ed", kind: .privateKey(pem: OpenSSHPrivateKey.encode(ed25519), passphrase: nil)),
            Credential(label: "EC", kind: .privateKey(pem: ecPEM, passphrase: nil)),
            Credential(label: "RSA", kind: .privateKey(pem: rsaPEM, passphrase: nil)),
            Credential(label: "pw", kind: .password("hunter2")),
        ]
    }

    var keys: [AgentKey] { DesktopAgentKeys.load(credentials).keys }
}

@Suite(.serialized) struct DesktopAgentTests {
    private func withAgent(approve: @escaping AgentResponder.Approve = { _ in true },
                           _ body: (DesktopAgent, String, Fixture) async throws -> Void) async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let fixture = try Fixture()
        let agent = DesktopAgent(socketPath: "\(dir.path)/rssh/agent.sock", approve: approve)
        try agent.start()
        defer { agent.stop() }
        agent.setKeys(fixture.keys)
        try await body(agent, agent.socketPath, fixture)
    }

    @Test func loadSkipsPasswordsAndReportsUnusableKeys() throws {
        let fixture = try Fixture()
        let broken = Credential(label: "bad", kind: .privateKey(pem: "not a key", passphrase: nil))
        let result = DesktopAgentKeys.load(fixture.credentials + [broken])
        #expect(result.keys.map(\.label) == ["Ed", "EC", "RSA"])
        #expect(result.skipped.map(\.credentialID) == [broken.id])
    }

    @Test func listsIdentities() async throws {
        try await withAgent { _, path, fixture in
            let client = try AgentClient(path: path)
            defer { client.close() }
            let ids = try client.identities()
            #expect(ids.map(\.blob) == fixture.keys.map(\.identity.publicBlob))
            #expect(ids.first?.comment == "ed-key")
        }
    }

    @Test func signsWithEd25519AndTheSignatureVerifies() async throws {
        try await withAgent { _, path, fixture in
            let client = try AgentClient(path: path)
            defer { client.close() }
            let data = Data("session-id+userauth".utf8)
            let reply = try #require(try client.sign(blob: fixture.keys[0].identity.publicBlob, data: data))
            #expect(reply.algorithm == "ssh-ed25519")
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: fixture.ed25519.publicKey)
            #expect(key.isValidSignature(reply.signature, for: data))
            #expect(!key.isValidSignature(reply.signature, for: Data("other".utf8)))
        }
    }

    @Test func signsWithECDSA() async throws {
        try await withAgent { _, path, fixture in
            let client = try AgentClient(path: path)
            defer { client.close() }
            let data = Data("ecdsa data".utf8)
            let reply = try #require(try client.sign(blob: fixture.keys[1].identity.publicBlob, data: data))
            #expect(reply.algorithm == "ecdsa-sha2-nistp256")
            var reader = WireReader(reply.signature)
            func scalar(_ mpint: Data) -> Data {
                let trimmed = mpint.drop { $0 == 0 }
                return Data(repeating: 0, count: max(0, 32 - trimmed.count)) + trimmed
            }
            let raw = scalar(try reader.string()) + scalar(try reader.string())
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
            #expect(fixture.p256.publicKey.isValidSignature(signature, for: data))
        }
    }

    @Test(arguments: [(UInt32(0x04), "rsa-sha2-512"), (UInt32(0x02), "rsa-sha2-256")])
    func signsWithRSAUsingTheRequestedHash(_ flags: UInt32, _ algorithm: String) async throws {
        try await withAgent { _, path, fixture in
            let client = try AgentClient(path: path)
            defer { client.close() }
            let data = Data("rsa data".utf8)
            let reply = try #require(try client.sign(blob: fixture.keys[2].identity.publicBlob, data: data, flags: flags))
            #expect(reply.algorithm == algorithm)
            let signature = _RSA.Signing.RSASignature(rawRepresentation: reply.signature)
            let valid = algorithm == "rsa-sha2-512"
                ? fixture.rsa.publicKey.isValidSignature(signature, for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
                : fixture.rsa.publicKey.isValidSignature(signature, for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
            #expect(valid)
        }
    }

    @Test func unknownKeyAndUnsupportedRequestsFail() async throws {
        try await withAgent { _, path, _ in
            let client = try AgentClient(path: path)
            defer { client.close() }
            let other = SSHPublicKey.ed25519Blob(Ed25519KeyPair.generate(comment: "x").publicKey)
            #expect(try client.sign(blob: other, data: Data("x".utf8)) == nil)
            #expect(try client.request(Data([17])) == Data([AgentMessage.failure])) // ADD_IDENTITY refused
            #expect(try client.request(Data([19])) == Data([AgentMessage.failure])) // REMOVE_ALL refused
        }
    }

    @Test func confirmHookCanDeny() async throws {
        let asked = Mutex<[String]>([])
        try await withAgent(approve: { request in
            asked.withLock { $0.append(request.keyLabel) }
            return false
        }) { _, path, fixture in
            let client = try AgentClient(path: path)
            defer { client.close() }
            #expect(try client.sign(blob: fixture.keys[0].identity.publicBlob, data: Data("x".utf8)) == nil)
            #expect(asked.withLock { $0 } == ["Ed"])
        }
    }

    @Test func lockedVaultOffersNothing() async throws {
        try await withAgent { agent, path, _ in
            agent.setKeys([])
            let client = try AgentClient(path: path)
            defer { client.close() }
            #expect(try client.identities().isEmpty)
        }
    }

    @Test func socketAndDirectoryArePrivate() async throws {
        try await withAgent { _, path, _ in
            var info = stat()
            #expect(lstat(path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(info.st_mode & S_IFMT == S_IFSOCK)
            #expect(lstat((path as NSString).deletingLastPathComponent, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o700)
        }
    }

    @Test func manyRequestsOnOneConnectionAndManyClients() async throws {
        try await withAgent { _, path, fixture in
            let clients = try (0..<8).map { _ in try AgentClient(path: path) }
            defer { clients.forEach { $0.close() } }
            for round in 0..<5 {
                for client in clients {
                    #expect(try client.identities().count == fixture.keys.count, "round \(round)")
                }
            }
        }
    }

    @Test func stopRemovesTheSocket() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let agent = DesktopAgent(socketPath: "\(dir.path)/a/agent.sock")
        try agent.start()
        #expect(FileManager.default.fileExists(atPath: agent.socketPath))
        agent.stop()
        #expect(!FileManager.default.fileExists(atPath: agent.socketPath))
        #expect(throws: UnixSocketError.self) { try UnixSocket.connect(to: agent.socketPath) }
    }

    @Test func refusesToReplaceSomethingThatIsNotASocket() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let path = "\(dir.path)/agent.sock"
        #expect(FileManager.default.createFile(atPath: path, contents: Data("keep me".utf8)))
        #expect(throws: UnixSocketError.pathOccupied(path)) { try DesktopAgent(socketPath: path).start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep me".utf8))
    }

    @Test func refusesASymlinkedDirectory() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        try FileManager.default.createDirectory(atPath: "\(dir.path)/real", withIntermediateDirectories: false)
        symlink("\(dir.path)/real", "\(dir.path)/link")
        #expect(throws: UnixSocketError.unsafeDirectory("\(dir.path)/link")) {
            try DesktopAgent(socketPath: "\(dir.path)/link/agent.sock").start()
        }
    }

    @Test func tooLongPath() {
        let path = "/tmp/" + String(repeating: "x", count: 200) + "/agent.sock"
        #expect(throws: UnixSocketError.pathTooLong(path)) { try UnixSocket.address(path) }
    }

    /// Throwaway key from `ssh-keygen -t ed25519 -a 4 -N "vault pass"` for this test only.
    static let encryptedPEM = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCvF0Bdv9
        iUY3RMBHa8OWTuAAAABAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIKVMfROCrzRLD/Pz
        FgWmm4eCDkLnnFEHG8rxD9qMSEPqAAAAkAAszxoOywvnDGAWZumvnFqFoTlTU9ByuhMti6
        /gcuQwExE2qccc7yhq3OCxHUTK/nxK2c+2A43NmkHdzRhV04guAeenyh8c18wTt4LFBeiy
        TxDiaLvfLgtCYYfU1g94Zaze9cmLZSBw23ocH20xOimDJqE/VvaleDmB+zDhJJ2mqR0iuj
        b/gnHYSZJLNF+KuA==
        -----END OPENSSH PRIVATE KEY-----
        """

    @Test func encryptedKeysWithTheirPassphraseAreOffered() throws {
        let withPass = Credential(label: "enc", kind: .privateKey(pem: Self.encryptedPEM, passphrase: "vault pass"))
        let without = Credential(label: "enc2", kind: .privateKey(pem: Self.encryptedPEM, passphrase: nil))
        let (keys, skipped) = DesktopAgentKeys.load([withPass, without])
        #expect(keys.map(\.label) == ["enc"])
        #expect(keys.first?.identity.publicBlob.base64EncodedString() == "AAAAC3NzaC1lZDI1NTE5AAAAIKVMfROCrzRLD/PzFgWmm4eCDkLnnFEHG8rxD9qMSEPq")
        #expect(skipped.map(\.credentialID) == [without.id])
        #expect(skipped.first?.error == .passphraseMissing)
    }

    @Test func defaultSocketPaths() {
        #expect(AgentSocketPath.default(platform: .linux, environment: ["XDG_RUNTIME_DIR": "/run/user/1000"], uid: 1000)
            == "/run/user/1000/rssh/agent.sock")
        #expect(AgentSocketPath.default(platform: .linux, environment: [:], uid: 1000) == "/tmp/rssh-1000/agent.sock")
        #expect(AgentSocketPath.default(platform: .macOS, environment: [:], home: "/Users/u")
            == "/Users/u/Library/Application Support/rSshTerm/agent.sock")
    }

    /// OpenSSH's own tools against the agent: `ssh-add -L` lists the vault keys, and `ssh-keygen -Y sign` signs
    /// through the agent (with only the public key on disk) and `-Y verify` accepts it.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")))
    func openSSHUsesTheAgent() async throws {
        try await withAgent { _, path, fixture in
            let env = ["SSH_AUTH_SOCK": path, "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
            let (listStatus, listed) = try run("/usr/bin/ssh-add", ["-L"], environment: env)
            #expect(listStatus == 0)
            #expect(listed.contains(fixture.ed25519.publicLine))

            let dir = try TempDir()
            defer { dir.cleanup() }
            let pub = "\(dir.path)/id.pub"
            try fixture.ed25519.publicLine.write(toFile: pub, atomically: true, encoding: .utf8)
            let message = "\(dir.path)/msg"
            try "hello agent".write(toFile: message, atomically: true, encoding: .utf8)
            let (signStatus, signOutput) = try run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", pub, "-n", "file", message],
                                                   environment: env)
            #expect(signStatus == 0, "\(signOutput)")
            let allowed = "\(dir.path)/allowed"
            try "me \(fixture.ed25519.publicLine)\n".write(toFile: allowed, atomically: true, encoding: .utf8)
            let (verifyStatus, verifyOutput) = try run("/usr/bin/ssh-keygen",
                ["-Y", "verify", "-f", allowed, "-I", "me", "-n", "file", "-s", message + ".sig"],
                environment: env, input: Data("hello agent".utf8))
            #expect(verifyStatus == 0, "\(verifyOutput)")
        }
    }
}
