import Citadel
import Crypto
import Foundation
import RSSHTunnel

/// The docker rig of `test/integration.sh`: an OpenSSH server and the screens behind it. Unset (a plain
/// `swift test`), the integration tests are skipped.
enum IntegrationEnvironment {
    static let env = ProcessInfo.processInfo.environment

    static var ssh: (host: String, port: Int, user: String, keyPath: String)? {
        guard let host = env["RSSH_RD_IT_SSH_HOST"], let user = env["RSSH_RD_IT_SSH_USER"],
              let key = env["RSSH_RD_IT_SSH_KEY"] else { return nil }
        return (host, Int(env["RSSH_RD_IT_SSH_PORT"] ?? "") ?? 22, user, key)
    }

    /// A screen as the SSH server sees it ("vnc:5900", "xrdp:3389").
    static func target(_ name: String) -> (host: String, port: Int)? {
        guard let host = env["RSSH_RD_IT_\(name)_HOST"], let port = Int(env["RSSH_RD_IT_\(name)_PORT"] ?? "") else {
            return nil
        }
        return (host, port)
    }

    static var enabled: Bool { ssh != nil }

    /// Logs in with the per-run ed25519 key. The rig's host key is new on every run, so it is not pinned here;
    /// the app pins host keys through the vault's known hosts.
    static func connect() async throws -> SSHClient {
        guard let ssh else { throw Missing() }
        let pem = try String(contentsOfFile: ssh.keyPath, encoding: .utf8)
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: pem)
        return try await SSHClient.connect(host: ssh.host, port: ssh.port,
                                           authenticationMethod: .ed25519(username: ssh.user, privateKey: key),
                                           hostKeyValidator: .acceptAnything(), reconnect: .never)
    }

    struct Missing: Error {}
}
