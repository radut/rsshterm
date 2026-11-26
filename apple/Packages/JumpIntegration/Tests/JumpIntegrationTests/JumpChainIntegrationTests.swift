@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOSSH
import Synchronization
import Testing
@testable import JumpIntegration

/// Through two real OpenSSH servers (docker/run.sh): the target is on a network only the jump server reaches.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RSSH_JUMP_IT_HOST"] != nil), .serialized)
struct JumpChainIntegrationTests {
    let env = ProcessInfo.processInfo.environment
    var jumpHost: String { env["RSSH_JUMP_IT_HOST"] ?? "" }
    var targetHost: String { env["RSSH_JUMP_IT_TARGET"] ?? "" }
    var jumpPassword: String { env["RSSH_JUMP_IT_JUMP_PASSWORD"] ?? "" }
    var targetPassword: String { env["RSSH_JUMP_IT_TARGET_PASSWORD"] ?? "" }

    /// Records the key each hop presents; refuses when told to.
    final class Recorder: NIOSSHClientServerAuthenticationDelegate, Sendable {
        let refuse: Bool
        let seen = Mutex<[String]>([])
        init(refuse: Bool = false) { self.refuse = refuse }
        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            seen.withLock { $0.append(String(openSSHPublicKey: hostKey)) }
            if refuse { validationCompletePromise.fail(RefusedKey()) } else { validationCompletePromise.succeed(()) }
        }
    }
    struct RefusedKey: Error {}

    func hops(jump: Recorder = Recorder(), target: Recorder = Recorder(),
              jumpLogins: [String]? = nil, targetLogins: [String]? = nil) -> [JumpChainConnector.Hop] {
        [JumpChainConnector.Hop(name: "jump", host: jumpHost, port: 22,
                                logins: (jumpLogins ?? [jumpPassword]).map { .passwordBased(username: "jump", password: $0) },
                                hostKeyValidator: .custom(jump)),
         JumpChainConnector.Hop(name: "target", host: targetHost, port: 22,
                                logins: (targetLogins ?? [targetPassword]).map { .passwordBased(username: "target", password: $0) },
                                hostKeyValidator: .custom(target))]
    }

    func run(_ command: String, on client: SSHClient) async throws -> String {
        let out = try await client.executeCommand(command)
        return String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theTargetIsOnlyReachableThroughTheJump() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await SSHClient.connect(host: targetHost, port: 22,
                                            authenticationMethod: .passwordBased(username: "target", password: targetPassword),
                                            hostKeyValidator: .acceptAnything(), reconnect: .never,
                                            connectTimeout: .seconds(5))
        }
    }

    @Test func connectsThroughTheJumpAndChecksEveryHostKey() async throws {
        let jumpKeys = Recorder()
        let targetKeys = Recorder()
        let connection = try await JumpChainConnector.connect(hops(jump: jumpKeys, target: targetKeys))
        #expect(connection.clients.count == 2)
        #expect(try await run("whoami", on: connection.destination) == "target")
        #expect(try await run("whoami", on: connection.clients[0]) == "jump")
        // two machines: different host names and host keys, each key checked once on its own hop
        #expect(try await run("hostname", on: connection.destination) != (try await run("hostname", on: connection.clients[0])))
        #expect(jumpKeys.seen.withLock { $0.count } == 1)
        #expect(targetKeys.seen.withLock { $0.count } == 1)
        #expect(jumpKeys.seen.withLock { $0 } != targetKeys.seen.withLock { $0 })
        await connection.close()
    }

    @Test func filesOverSFTPWorkThroughTheJump() async throws {
        let connection = try await JumpChainConnector.connect(hops())
        let sftp = try await connection.destination.openSFTP()
        let names = try await sftp.listDirectory(atPath: "/home").flatMap(\.components).map(\.filename)
        #expect(names.contains("target"))
        try await sftp.close()
        await connection.close()
    }

    @Test func aRefusedLoginNamesItsHop() async throws {
        do {
            _ = try await JumpChainConnector.connect(hops(targetLogins: ["wrong"]))
            Issue.record("connected with a wrong password")
        } catch {
            #expect(error.index == 1)
            #expect(error.name == "target")
            #expect(JumpChainConnector.isRefusedLogin(error.underlying))
        }
        do {
            _ = try await JumpChainConnector.connect(hops(jumpLogins: ["wrong"]))
            Issue.record("connected with a wrong password")
        } catch {
            #expect(error.index == 0)
            #expect(error.name == "jump")
        }
    }

    @Test func theNextLoginOfAHopIsTriedAfterARefusal() async throws {
        let connection = try await JumpChainConnector.connect(hops(jumpLogins: ["wrong", jumpPassword]))
        #expect(try await run("whoami", on: connection.destination) == "target")
        await connection.close()
    }

    @Test func aRefusedHostKeyStopsAtThatHop() async throws {
        do {
            _ = try await JumpChainConnector.connect(hops(target: Recorder(refuse: true)))
            Issue.record("connected past a refused host key")
        } catch {
            #expect(error.index == 1)
        }
    }

    @Test func closingTearsDownEveryHop() async throws {
        let connection = try await JumpChainConnector.connect(hops())
        await connection.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(connection.clients.allSatisfy { !$0.isConnected })
    }

    @Test func aDroppedJumpHostClosesTheDestination() async throws {
        let connection = try await JumpChainConnector.connect(hops())
        try await connection.clients[0].close()
        try await Task.sleep(for: .seconds(1))
        #expect(!connection.destination.isConnected)
    }

    /// The Files tab keeps only the destination (its SFTP source closes it): the jump hosts must go with it.
    @Test func closingOnlyTheDestinationClosesTheJumpHosts() async throws {
        let connection = try await JumpChainConnector.connect(hops())
        try await connection.destination.close()
        try await Task.sleep(for: .seconds(1))
        #expect(!connection.clients[0].isConnected)
    }
}
