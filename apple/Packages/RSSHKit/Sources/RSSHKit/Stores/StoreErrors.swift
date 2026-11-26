import Foundation

/// Failures of a store that talks to a server (Google Drive, later S3).
public enum RemoteStoreError: Error, Equatable, LocalizedError {
    /// The access token was refused: sign in again.
    case unauthorized
    /// Any other non-success status, with the server's own message when it sent one.
    case http(status: Int, message: String)
    /// The server answered 2xx with a body this client cannot read.
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The sign-in has expired or was refused. Sign in again."
        case let .http(status, message): message.isEmpty ? "The server answered \(status)." : "The server answered \(status): \(message)"
        case let .unexpectedResponse(what): "The server's answer could not be read (\(what))."
        }
    }
}

extension VaultStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .conflict: "The vault was changed elsewhere since it was loaded. Sync again."
        }
    }
}

extension Error {
    /// A message fit to show in the UI: `LocalizedError`'s description when there is one.
    var userMessage: String {
        (self as? any LocalizedError)?.errorDescription ?? String(describing: self)
    }
}
