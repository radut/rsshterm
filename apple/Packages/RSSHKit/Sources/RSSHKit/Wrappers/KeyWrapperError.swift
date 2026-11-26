import Foundation

/// Why a wrapper could not wrap or unwrap. Messages are for people and never carry key material or tokens.
public enum KeyWrapperError: Error, Equatable, Sendable, LocalizedError {
    /// The account behind the key refused who we are (rejected or expired sign-in): sign in again.
    case needsSignIn(String)
    /// No answer, throttled or a server error: the same call may work later.
    case retryable(String)
    /// The key service answered with an error that retrying will not fix.
    case rejected(status: Int, message: String)
    /// A 2xx answer we could not read.
    case invalidResponse(String)
    /// The settings do not describe a usable key.
    case notConfigured(String)

    public var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .needsSignIn(let m): "Sign in again. \(m)"
        case .retryable(let m): "Could not reach the key service, try again. \(m)"
        case .rejected(let status, let m): "The key service refused the request (HTTP \(status)). \(m)"
        case .invalidResponse(let m): "The key service sent an answer rSshTerm could not read. \(m)"
        case .notConfigured(let m): "The key is not set up. \(m)"
        }
    }
}
