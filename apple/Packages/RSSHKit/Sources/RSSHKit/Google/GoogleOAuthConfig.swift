import Foundation

/// The desktop app's Google OAuth client ("Desktop app" type in Google Cloud). Google treats a desktop client's
/// secret as not confidential (it ships inside every copy of the app; PKCE protects the code), but it is still never
/// committed: it comes from the environment or the client JSON the owner downloads (docs/setup.md).
public struct GoogleOAuthConfig: Sendable, Equatable {
    /// Hidden app folder in the user's Drive, visible only to this client: all the vault needs.
    public static let driveAppDataScope = "https://www.googleapis.com/auth/drive.appdata"

    public var clientID: String
    public var clientSecret: String?
    public var scopes: [String]
    public var authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public var tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public var revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    public init(clientID: String, clientSecret: String? = nil, scopes: [String] = [GoogleOAuthConfig.driveAppDataScope]) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }

    /// `RSSH_GOOGLE_CLIENT_ID` (+ `RSSH_GOOGLE_CLIENT_SECRET`), or `RSSH_GOOGLE_CLIENT_FILE`: the client JSON.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws
        -> GoogleOAuthConfig {
        if let id = environment["RSSH_GOOGLE_CLIENT_ID"], !id.isEmpty {
            let secret = environment["RSSH_GOOGLE_CLIENT_SECRET"].flatMap { $0.isEmpty ? nil : $0 }
            return GoogleOAuthConfig(clientID: id, clientSecret: secret)
        }
        if let path = environment["RSSH_GOOGLE_CLIENT_FILE"], !path.isEmpty {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw GoogleOAuthError.notConfigured("\(path) could not be read.")
            }
            return try fromJSON(data)
        }
        throw GoogleOAuthError.notConfigured("Set RSSH_GOOGLE_CLIENT_ID or RSSH_GOOGLE_CLIENT_FILE.")
    }

    /// Google's downloaded client file (`{"installed": {...}}`) or a flat `{"client_id", "client_secret"}`.
    public static func fromJSON(_ data: Data) throws -> GoogleOAuthConfig {
        struct Client: Decodable {
            let client_id: String?
            let client_secret: String?
        }
        struct File: Decodable {
            let installed: Client?
            let client_id: String?
            let client_secret: String?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              let id = file.installed?.client_id ?? file.client_id, !id.isEmpty else {
            throw GoogleOAuthError.notConfigured("The client file has no client_id.")
        }
        return GoogleOAuthConfig(clientID: id, clientSecret: file.installed?.client_secret ?? file.client_secret)
    }
}

/// Why signing in to Google or getting a token failed. Messages are for people and never carry tokens.
public enum GoogleOAuthError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured(String)
    /// Google sent the user back with an error (`access_denied` when they pressed Cancel).
    case denied(String)
    /// The redirect's `state` is not the one this sign-in sent: an answer to someone else's request.
    case stateMismatch
    case missingCode
    /// The user unticked the Drive app-data permission on the consent screen.
    case scopeNotGranted
    /// No sign-in, or the refresh token was revoked or expired: sign in again.
    case needsSignIn
    /// No redirect arrived in time.
    case timedOut
    case browser(String)
    case loopback(String)
    case http(status: Int, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let m): "Google sign-in is not set up. \(m)"
        case .denied(let e): "Google sign-in was not allowed (\(e))."
        case .stateMismatch: "The answer from Google did not belong to this sign-in. Try again."
        case .missingCode: "Google's answer had no authorization code. Try again."
        case .scopeNotGranted: "rSshTerm needs the permission to keep its own data in your Google Drive."
        case .needsSignIn: "Sign in to Google again."
        case .timedOut: "Google sign-in did not finish in time."
        case .browser(let m): "The browser could not be opened. \(m)"
        case .loopback(let m): "rSshTerm could not wait for Google's answer. \(m)"
        case let .http(status, m): m.isEmpty ? "Google answered \(status)." : "Google answered \(status): \(m)"
        case .invalidResponse(let m): "Google's answer could not be read (\(m))."
        }
    }
}
