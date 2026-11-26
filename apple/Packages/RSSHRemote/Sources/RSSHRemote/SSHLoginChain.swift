import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import RSSHKit

/// Several logins tried in order on one connection, like `ssh` with an agent: the server's own credential first,
/// then the other vault keys. Each `SSHAuthenticationMethod` offers once and fails on its second call (the server
/// refused it), which is when the chain moves on to the next one.
///
/// OpenSSH closes the connection after `MaxAuthTries` (6 by default) failed offers, so `SSHLogins.plan` caps the list.
public final class SSHLoginChain: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    // Only touched on the connection's event loop (NIOSSH calls the delegate there).
    private var methods: [SSHAuthenticationMethod]

    public init(_ methods: [SSHAuthenticationMethod]) { self.methods = methods }

    public var remaining: Int { methods.count }

    public func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                       nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard let first = methods.first else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }
        let loop = nextChallengePromise.futureResult.eventLoop
        let attempt = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        nextChallengePromise.completeWith(attempt.futureResult.flatMapError { [self] _ in
            // This method is used up (offered and refused, or not allowed by the server): try the next.
            if !methods.isEmpty { methods.removeFirst() }
            let next = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: next)
            return next.futureResult
        })
        first.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: attempt)
    }
}

/// Which vault secrets a connection offers, in order.
public enum SSHLogins {
    /// OpenSSH's default MaxAuthTries is 6; one is left for the server's own accounting.
    public static let maxOffers = 5

    /// The server's credential (when it has one), then every other private key of the vault when `agentKeys` is
    /// on (the built-in agent's keys), without duplicates, capped at `maxOffers`. Passwords other than the
    /// server's own are never tried: sending a password to a server it was not saved for would leak it.
    public static func plan(credential: Credential?, vaultCredentials: [Credential], agentKeys: Bool,
                            limit: Int = maxOffers) -> [Credential] {
        var out: [Credential] = []
        if let credential { out.append(credential) }
        if agentKeys {
            for key in vaultCredentials where key.isPrivateKey && !out.contains(where: { $0.id == key.id }) {
                out.append(key)
            }
        }
        return Array(out.prefix(max(0, limit)))
    }

    /// The Citadel login for `username` with these secrets. Keys that cannot be read are left out (so one bad key
    /// in the vault does not block the others); when nothing is left, the first key's error is thrown.
    public static func method(username: String, secrets: [Credential.Kind]) throws(SSHFailure) -> SSHAuthenticationMethod {
        var methods: [SSHAuthenticationMethod] = []
        var firstError: SSHFailure?
        for secret in secrets {
            do { methods.append(try SSHAuthFactory.method(username: username, secret: secret)) } catch {
                if firstError == nil { firstError = error }
            }
        }
        guard !methods.isEmpty else { throw firstError ?? .noCredential }
        return methods.count == 1 ? methods[0] : .custom(SSHLoginChain(methods))
    }
}
