import Foundation

/// One way to log in that a session tries: a vault credential (or a secret typed just now) with a label to show.
public struct QuickLogin: Hashable, Sendable {
    public static let maxAutomaticAttempts = 5

    public var label: String
    public var secret: Credential.Kind
    /// The vault credential it came from; nil for a password typed once.
    public var credentialID: UUID?

    public init(label: String, secret: Credential.Kind, credentialID: UUID? = nil) {
        self.label = label
        self.secret = secret
        self.credentialID = credentialID
    }

    public init(credential: Credential) {
        self.init(label: credential.label, secret: credential.kind, credentialID: credential.id)
    }

    /// The keys to try without asking, like ssh's identity files: private keys that open without a prompt (plain,
    /// or encrypted with the passphrase stored), ed25519 before RSA, vault order otherwise, at most five.
    public static func automatic(from credentials: [Credential]) -> [QuickLogin] {
        let ranked: [(rank: Int, login: QuickLogin)] = credentials.compactMap { credential in
            guard case .privateKey(let pem, let passphrase) = credential.kind,
                  case .openSSH(let algorithm, _)? = try? LoginKey.plan(pem: pem, passphrase: passphrase)
            else { return nil }
            return (algorithm == .ed25519 ? 0 : 1, QuickLogin(credential: credential))
        }
        let ordered = ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
        return ordered.prefix(maxAutomaticAttempts).map(\.element.login)
    }
}

extension SSHFailure {
    /// True when this login was refused or unusable, so the next one may work. Network and host key failures are
    /// about the server, not the login: they stop the round.
    public var triesNextLogin: Bool {
        switch self {
        case .authenticationFailed, .passphraseRequired, .wrongPassphrase, .unsupportedKey, .invalidKey: true
        default: false
        }
    }

    /// True when the connection itself was lost (network, timeout, a reset): connecting again needs no decision from
    /// the user, so the app reconnects on its own. A refused login, a missing credential or a host key question would
    /// fail the same way again, or must not be skipped, so those wait for the user.
    public var reconnectsAutomatically: Bool {
        switch self {
        case .hostUnreachable, .timedOut, .unknown: true
        case .viaJumpHost(_, let failure): failure.reconnectsAutomatically
        default: false
        }
    }
}
