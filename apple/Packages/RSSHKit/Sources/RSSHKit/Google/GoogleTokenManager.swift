import Foundation

/// Keeps the desktop's Google tokens in a `SecretStore` and hands out a valid access token, refreshing it shortly
/// before it expires (one refresh for any number of concurrent callers). Plug into `GoogleDriveVaultStore` as
/// `accessToken: { try await manager.accessToken() }`.
public actor GoogleTokenManager {
    public static let account = "google-oauth"
    /// Refresh this long before the access token expires, so a request never goes out with a dying token.
    static let refreshMargin: TimeInterval = 60

    private let oauth: GoogleDesktopOAuth
    private let secrets: any SecretStore
    private let now: @Sendable () -> Date
    private var cached: OAuthTokens?
    private var refreshing: Task<OAuthTokens, any Error>?

    public init(oauth: GoogleDesktopOAuth, secrets: any SecretStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.oauth = oauth
        self.secrets = secrets
        self.now = now
    }

    public func isSignedIn() async -> Bool { ((try? await stored()) ?? nil) != nil }

    /// Throws `GoogleOAuthError.needsSignIn` when there is no sign-in or Google revoked it.
    public func accessToken() async throws -> String {
        if let refreshing { return try await refreshing.value.accessToken }
        guard let tokens = try await stored() else { throw GoogleOAuthError.needsSignIn }
        if tokens.expiresAt > now().addingTimeInterval(Self.refreshMargin) { return tokens.accessToken }
        // Another caller may have started a refresh while this one read the store.
        if let refreshing { return try await refreshing.value.accessToken }
        guard let refreshToken = tokens.refreshToken else { throw GoogleOAuthError.needsSignIn }
        let task = Task { try await self.refreshAndStore(refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value.accessToken
    }

    public func signIn(browser: any BrowserOpener, receiver: any RedirectReceiver) async throws {
        let tokens = try await oauth.signIn(browser: browser, receiver: receiver)
        try await save(tokens)
    }

    /// Forgets the tokens here, then revokes the grant at Google (its error, if any, is thrown after forgetting).
    public func signOut() async throws {
        let tokens = try await stored()
        cached = nil
        try await secrets.delete(account: Self.account)
        if let token = tokens?.refreshToken ?? tokens?.accessToken { try await oauth.revoke(token: token) }
    }

    private func refreshAndStore(_ refreshToken: String) async throws -> OAuthTokens {
        do {
            let tokens = try await oauth.refresh(refreshToken: refreshToken)
            try await save(tokens)
            return tokens
        } catch GoogleOAuthError.needsSignIn {
            cached = nil
            try? await secrets.delete(account: Self.account)
            throw GoogleOAuthError.needsSignIn
        }
    }

    private func stored() async throws -> OAuthTokens? {
        if let cached { return cached }
        guard let data = try await secrets.read(account: Self.account) else { return nil }
        guard let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else {
            throw GoogleOAuthError.invalidResponse("stored sign-in")
        }
        cached = tokens
        return tokens
    }

    private func save(_ tokens: OAuthTokens) async throws {
        try await secrets.write(try JSONEncoder().encode(tokens), account: Self.account)
        cached = tokens
    }
}
