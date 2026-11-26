import Foundation
import RSSHKit
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Where the built-in agent listens: `$XDG_RUNTIME_DIR/rssh/agent.sock` on Linux (a per-user tmpfs, 0700), else
/// `/tmp/rssh-<uid>/agent.sock`; `~/Library/Application Support/rSshTerm/agent.sock` on macOS.
public enum AgentSocketPath {
    public static func `default`(platform: Platform = .current, environment: [String: String],
                                 home: String = NSHomeDirectory(), uid: UInt32 = getuid()) -> String {
        switch platform {
        case .macOS:
            return "\(home)/Library/Application Support/rSshTerm/agent.sock"
        case .linux:
            if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
                return "\(runtime)/rssh/agent.sock"
            }
            return "/tmp/rssh-\(uid)/agent.sock"
        }
    }
}

/// Turns the unlocked vault's private keys into agent keys (encrypted ones with their stored passphrase, through
/// RSSHKit's bcrypt + AES). Passwords are skipped silently; keys that cannot be
/// read come back in `skipped` with the reason, so Settings can say which key the agent does not offer.
public enum DesktopAgentKeys {
    public typealias Decrypt = (_ pem: String, _ passphrase: String) throws -> Data

    public static func load(_ credentials: [Credential], decrypt: Decrypt = OpenSSHKeyDecryption.decrypt)
        -> (keys: [AgentKey], skipped: [(credentialID: UUID, error: AgentKeyError)]) {
        var keys: [AgentKey] = []
        var skipped: [(UUID, AgentKeyError)] = []
        for credential in credentials {
            guard case .privateKey = credential.kind else { continue }
            do { keys.append(try AgentKey.load(credential, decrypt: decrypt)) } catch { skipped.append((credential.id, error)) }
        }
        return (keys, skipped)
    }
}

/// The built-in ssh-agent: serves the vault's keys on a unix socket to every local tab (SSH_AUTH_SOCK), so a plain
/// `ssh host` uses them. It speaks RSSHKit's agent protocol: list identities and sign (ed25519, ECDSA, RSA with
/// rsa-sha2-256/512); add, remove, lock and extensions are refused, the vault is the only source of keys.
///
/// One accept thread and one thread per client, each polling so `stop()` ends them within `pollInterval`. Every
/// sign request goes through `approve` (the per-use confirm hook; the default allows).
public final class DesktopAgent: Sendable {
    public let socketPath: String
    public static let maximumClients = 64

    private let approve: AgentResponder.Approve
    private let keys = Mutex<[AgentKey]>([])
    private let state = Mutex<State>(State())
    private let pollInterval: Int32 = 200

    private struct State {
        var listener: Int32 = -1
        var running = false
        var clients = 0
    }

    public init(socketPath: String, approve: @escaping AgentResponder.Approve = { _ in true }) {
        self.socketPath = socketPath
        self.approve = approve
    }

    /// The keys to offer; an empty list while the vault is locked.
    public func setKeys(_ newKeys: [AgentKey]) { keys.withLock { $0 = newKeys } }
    public var offeredKeys: [AgentKey] { keys.withLock { $0 } }
    public var isRunning: Bool { state.withLock { $0.running } }

    /// Creates the private directory and the socket and starts accepting.
    public func start() throws(UnixSocketError) {
        guard !isRunning else { return }
        try UnixSocket.ensurePrivateDirectory((socketPath as NSString).deletingLastPathComponent)
        let fd = try UnixSocket.listen(at: socketPath)
        state.withLock {
            $0.listener = fd
            $0.running = true
        }
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    /// Stops accepting and serving, and removes the socket.
    public func stop() {
        let fd: Int32 = state.withLock { s in
            defer {
                s.running = false
                s.listener = -1
            }
            return s.running ? s.listener : -1
        }
        guard fd >= 0 else { return }
        unlink(socketPath)
        // The accept thread closes the listener when it sees `running` false.
    }

    deinit { stop() }

    private func acceptLoop(_ listener: Int32) {
        defer { close(listener) }
        while isRunning {
            guard UnixSocket.waitReadable(listener, milliseconds: pollInterval) else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let admitted = state.withLock { s in
                guard s.clients < Self.maximumClients else { return false }
                s.clients += 1
                return true
            }
            guard admitted else { close(client); continue }
            Thread.detachNewThread { [self] in
                serve(client)
                state.withLock { $0.clients -= 1 }
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var framer = AgentFramer()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while isRunning {
            guard UnixSocket.waitReadable(fd, milliseconds: pollInterval) else { continue }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return }
            let messages: [Data]
            do { messages = try framer.append(buffer[0..<count]) } catch { return }
            for message in messages {
                let reply = respond(to: message)
                guard UnixSocket.writeAll(fd, AgentFramer.frame(reply)) else { return }
            }
        }
    }

    /// Runs the async responder from this client's own thread (never a cooperative-pool thread).
    private func respond(to message: Data) -> Data {
        let responder = AgentResponder(keys: offeredKeys, approve: approve)
        let result = Mutex<Data?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task {
            let reply = await responder.respond(to: message)
            result.withLock { $0 = reply }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 } ?? AgentResponse.failure.payload
    }
}
