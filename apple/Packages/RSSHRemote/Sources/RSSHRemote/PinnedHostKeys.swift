import Citadel
import Foundation
import NIOCore
import NIOSSH
import RSSHKit
import Synchronization

/// Why a handshake was stopped at the host key.
public enum HostKeyRefusal: Error, Equatable, Sendable {
    /// Never seen: show the fingerprint, pin it on "Trust", connect again.
    case unknown(KnownHost)
    /// Pinned to another key: possible man-in-the-middle; never connect.
    case changed(expected: KnownHost, presented: KnownHost)
}

/// Checks the server's host key during the handshake against the vault's pinned keys (trust on first use). It
/// decides at once and never waits for the user (Citadel gives the whole handshake a deadline).
public final class PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: String
    private let port: Int
    private let known: [KnownHost]
    private let verdict = Mutex<HostKeyRefusal?>(nil)

    public init(host: String, port: Int, known: [KnownHost]) {
        self.host = host
        self.port = port
        self.known = known
    }

    /// Why the key was refused, when it was.
    public var refusal: HostKeyRefusal? { verdict.withLock { $0 } }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        switch Self.decide(openSSHLine: line, host: host, port: port, known: known) {
        case .success:
            validationCompletePromise.succeed(())
        case .failure(let refusal):
            verdict.withLock { $0 = refusal }
            validationCompletePromise.fail(refusal)
        }
    }

    /// The decision on one presented key line; split out so it is testable without a handshake.
    public static func decide(openSSHLine line: String, host: String, port: Int,
                              known: [KnownHost]) -> Result<Void, HostKeyRefusal> {
        guard let parsed = try? HostKeyFingerprint.parse(openSSHPublicKey: line) else {
            return .failure(.unknown(KnownHost(host: host, port: port, keyType: "unknown", fingerprint: "")))
        }
        let presented = KnownHost(host: host, port: port, keyType: parsed.keyType, fingerprint: parsed.fingerprint)
        switch HostKeyPolicy.evaluate(presented, against: known) {
        case .accept: return .success(())
        case .ask: return .failure(.unknown(presented))
        case .refuse(let expected): return .failure(.changed(expected: expected, presented: presented))
        }
    }
}
