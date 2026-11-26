import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tokens from Google's token endpoint. Kept in a `SecretStore` by `GoogleTokenManager`.
public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

/// Google sign-in for installed apps: authorization code with PKCE and a loopback redirect
/// (https://developers.google.com/identity/protocols/oauth2/native-app), then refresh-token grants. Pure Swift on
/// `HTTPTransport`, so it runs on Linux and macOS and tests script Google's answers.
public struct GoogleDesktopOAuth: Sendable {
    public let config: GoogleOAuthConfig
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(config: GoogleOAuthConfig, transport: any HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.transport = transport
        self.now = now
    }

    /// The consent page. `access_type=offline` asks for a refresh token; `prompt=consent` makes Google send one again
    /// when the user signs in a second time.
    public func authorizationURL(pkce: PKCE, state: String, redirectURI: String) -> URL {
        var c = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    /// Opens the consent page, waits for the redirect, checks `state`, exchanges the code. Closes `receiver`.
    public func signIn(browser: any BrowserOpener, receiver: any RedirectReceiver,
                       timeout: TimeInterval = 300) async throws -> OAuthTokens {
        defer { receiver.close() }
        let pkce = PKCE.generate()
        let state = PKCE.randomToken(bytes: 16)
        try await browser.open(authorizationURL(pkce: pkce, state: state, redirectURI: receiver.redirectURI))
        let redirect = try await receiver.waitForRedirect(timeout: timeout)
        let items = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard value("state") == state else { throw GoogleOAuthError.stateMismatch }
        if let error = value("error") { throw GoogleOAuthError.denied(error) }
        guard let code = value("code"), !code.isEmpty else { throw GoogleOAuthError.missingCode }
        return try await exchange(code: code, verifier: pkce.verifier, redirectURI: receiver.redirectURI)
    }

    public func exchange(code: String, verifier: String, redirectURI: String) async throws -> OAuthTokens {
        let tokens = try await token([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
        ], previousRefreshToken: nil)
        if let scope = tokens.scope,
           !config.scopes.allSatisfy(scope.split(separator: " ").map(String.init).contains) {
            throw GoogleOAuthError.scopeNotGranted
        }
        return tokens
    }

    /// New access token; Google usually sends no new refresh token, so the old one is kept.
    public func refresh(refreshToken: String) async throws -> OAuthTokens {
        try await token([("grant_type", "refresh_token"), ("refresh_token", refreshToken)],
                        previousRefreshToken: refreshToken)
    }

    /// Revokes the grant (refresh or access token) at Google.
    public func revoke(token: String) async throws {
        let (status, data) = try await post(config.revokeEndpoint, [("token", token)])
        // 400 invalid_token: already revoked or expired, which is what was wanted.
        guard (200..<300).contains(status) || status == 400 else { throw Self.error(status, data) }
    }

    private func token(_ fields: [(String, String)], previousRefreshToken: String?) async throws -> OAuthTokens {
        var form = fields + [("client_id", config.clientID)]
        if let secret = config.clientSecret { form.append(("client_secret", secret)) }
        let sentAt = now()
        let (status, data) = try await post(config.tokenEndpoint, form)
        guard (200..<300).contains(status) else { throw Self.error(status, data) }
        struct Body: Decodable {
            let access_token: String
            let expires_in: Double?
            let refresh_token: String?
            let scope: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data), !body.access_token.isEmpty else {
            throw GoogleOAuthError.invalidResponse("token")
        }
        return OAuthTokens(accessToken: body.access_token, refreshToken: body.refresh_token ?? previousRefreshToken,
                           expiresAt: sentAt.addingTimeInterval(body.expires_in ?? 3600), scope: body.scope)
    }

    private func post(_ url: URL, _ form: [(String, String)]) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { "\(Self.escape($0.0))=\(Self.escape($0.1))" }.joined(separator: "&").utf8)
        let (data, response) = try await transport.send(req)
        return (response.statusCode, data)
    }

    /// `invalid_grant` (revoked, expired or reused code/refresh token) means signing in again.
    private static func error(_ status: Int, _ data: Data) -> GoogleOAuthError {
        struct Body: Decodable {
            let error: String?
            let error_description: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        if body?.error == "invalid_grant" { return .needsSignIn }
        return .http(status: status, message: body?.error_description ?? body?.error ?? "")
    }

    private static func escape(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}
