/// Why a session could not start or ended, in words a user can act on. The app maps library errors to these.
public enum SSHFailure: Error, Hashable, Sendable {
    case hostUnreachable(host: String, detail: String)
    case timedOut(host: String)
    case authenticationFailed
    case passphraseRequired
    case wrongPassphrase
    case unsupportedKey(String)
    case invalidKey(String)
    case hostKeyRejectedByUser
    case hostKeyChanged(expected: String, presented: String)
    case noCredential
    case shellFailed(String)
    case unknown(String)
    /// A jump host on the way failed (by its name in the chain); the target was not reached.
    indirect case viaJumpHost(String, SSHFailure)
    /// The server's jump chain cannot be followed (a circle, too long, a deleted jump server).
    case jumpChain(JumpChainError)

    public var message: String {
        switch self {
        case .hostUnreachable(let host, let detail):
            return "Could not reach \(host): \(detail). Check the address, the port and your network."
        case .timedOut(let host):
            return "\(host) did not answer in time. Check the address and that the server is up."
        case .authenticationFailed:
            return "The server refused the login. Check the username and the password or key."
        case .passphraseRequired:
            return "This private key is protected by a passphrase. Enter it in the key's settings."
        case .wrongPassphrase:
            return "The passphrase does not open this private key."
        case .unsupportedKey(let type):
            return "Keys of type \(type) are not supported yet. Use an ed25519 or RSA key."
        case .invalidKey(let reason):
            return reason
        case .hostKeyRejectedByUser:
            return "You did not trust the server's host key, so the connection was closed."
        case .hostKeyChanged(let expected, let presented):
            return "The server's host key changed. Someone could be intercepting the connection. "
                + "Expected \(expected), got \(presented). If the server was reinstalled, remove it from known hosts and connect again."
        case .noCredential:
            return "This server has no password or key. Add one to connect."
        case .shellFailed(let detail):
            return "The server did not open a shell: \(detail)."
        case .unknown(let detail):
            return "The connection failed: \(detail)."
        case .viaJumpHost(let hop, let failure):
            return "Jump host \(hop): \(failure.message)"
        case .jumpChain(let error):
            return error.message
        }
    }
}
