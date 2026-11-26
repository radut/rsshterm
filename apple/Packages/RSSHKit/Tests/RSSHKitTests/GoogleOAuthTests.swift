import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RSSHKit

/// Plays the browser and Google's consent page: answers the redirect with what `respond` makes of the auth URL.
final class FakeBrowser: BrowserOpener, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [URL] = []
    var opened: [URL] { lock.withLock { _opened } }
    let receiver: FakeReceiver
    let respond: @Sendable ([String: String]) -> String

    init(receiver: FakeReceiver, respond: @escaping @Sendable ([String: String]) -> String) {
        self.receiver = receiver
        self.respond = respond
    }

    func open(_ url: URL) async throws {
        lock.withLock { _opened.append(url) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        receiver.deliver(URL(string: "\(receiver.redirectURI)/?\(respond(query))")!)
    }
}

final class FakeReceiver: RedirectReceiver, @unchecked Sendable {
    let redirectURI = "http://127.0.0.1:54321"
    private let lock = NSLock()
    private var url: URL?
    private(set) var closed = false

    func deliver(_ url: URL) { lock.withLock { self.url = url } }

    func waitForRedirect(timeout: TimeInterval) async throws -> URL {
        guard let url = lock.withLock({ self.url }) else { throw GoogleOAuthError.timedOut }
        return url
    }

    func close() { lock.withLock { closed = true } }
}

@Suite struct GoogleOAuthTests {
    static let config = GoogleOAuthConfig(clientID: "123-abc.apps.googleusercontent.com", clientSecret: "not-really-secret")
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let tokenJSON = #"{"access_token":"at-1","expires_in":3599,"refresh_token":"rt-1","scope":"https://www.googleapis.com/auth/drive.appdata","token_type":"Bearer"}"#

    func oauth(_ t: FakeTransport) -> GoogleDesktopOAuth {
        GoogleDesktopOAuth(config: Self.config, transport: t, now: { Self.t0 })
    }

    static func form(_ req: URLRequest) -> [String: String] {
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    // MARK: config

    @Test func configFromEnvironment() throws {
        let c = try GoogleOAuthConfig.fromEnvironment(["RSSH_GOOGLE_CLIENT_ID": "id.apps", "RSSH_GOOGLE_CLIENT_SECRET": "s"])
        #expect(c.clientID == "id.apps")
        #expect(c.clientSecret == "s")
        #expect(c.scopes == ["https://www.googleapis.com/auth/drive.appdata"])
        #expect(throws: GoogleOAuthError.self) { try GoogleOAuthConfig.fromEnvironment([:]) }
    }

    @Test func configFromGoogleDownloadedJSON() throws {
        let json = #"{"installed":{"client_id":"id.apps","client_secret":"s","redirect_uris":["http://localhost"]}}"#
        let c = try GoogleOAuthConfig.fromJSON(Data(json.utf8))
        #expect(c.clientID == "id.apps")
        #expect(c.clientSecret == "s")
        let flat = try GoogleOAuthConfig.fromJSON(Data(#"{"client_id":"id2"}"#.utf8))
        #expect(flat.clientSecret == nil)
    }

    // MARK: PKCE and the consent URL

    /// RFC 7636 appendix B.
    @Test func pkceChallengeMatchesTheRFC() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func pkceVerifierIsLongAndURLSafe() {
        let a = PKCE.generate(), b = PKCE.generate()
        #expect(a.verifier != b.verifier)
        #expect((43...128).contains(a.verifier.count))
        #expect(a.verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    @Test func authorizationURLAsksForDriveAppDataOnlyWithPKCE() throws {
        let url = oauth(FakeTransport([])).authorizationURL(pkce: PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                                                           state: "st", redirectURI: "http://127.0.0.1:5000")
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.host == "accounts.google.com")
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(q["client_id"] == Self.config.clientID)
        #expect(q["redirect_uri"] == "http://127.0.0.1:5000")
        #expect(q["response_type"] == "code")
        #expect(q["scope"] == "https://www.googleapis.com/auth/drive.appdata")
        #expect(q["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == "st")
        #expect(q["access_type"] == "offline")
    }

    // MARK: sign-in

    @Test func signInExchangesTheCodeWithTheVerifier() async throws {
        let t = FakeTransport([.init(200, Self.tokenJSON)])
        let receiver = FakeReceiver()
        let browser = FakeBrowser(receiver: receiver) { q in "code=4%2Fcode-xyz&state=\(q["state"] ?? "")&scope=x" }
        let tokens = try await oauth(t).signIn(browser: browser, receiver: receiver)
        #expect(tokens == OAuthTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: Self.t0.addingTimeInterval(3599),
                                      scope: "https://www.googleapis.com/auth/drive.appdata"))
        #expect(receiver.closed)
        let req = try #require(await t.sent.first)
        #expect(req.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let form = Self.form(req)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "4/code-xyz")
        #expect(form["redirect_uri"] == "http://127.0.0.1:54321")
        #expect(form["client_id"] == Self.config.clientID)
        #expect(form["client_secret"] == "not-really-secret")
        // The verifier sent is the one whose challenge went to the browser.
        let sentChallenge = URLComponents(url: try #require(browser.opened.first), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code_challenge" })?.value
        #expect(PKCE(verifier: try #require(form["code_verifier"])).challenge == sentChallenge)
    }

    @Test func wrongStateIsRefusedBeforeAnyExchange() async throws {
        let t = FakeTransport([.init(200, Self.tokenJSON)])
        let receiver = FakeReceiver()
        let browser = FakeBrowser(receiver: receiver) { _ in "code=c&state=forged" }
        await #expect(throws: GoogleOAuthError.stateMismatch) { try await oauth(t).signIn(browser: browser, receiver: receiver) }
        #expect(await t.sent.isEmpty)
    }

    @Test func refusedConsentIsReported() async throws {
        let receiver = FakeReceiver()
        let browser = FakeBrowser(receiver: receiver) { q in "error=access_denied&state=\(q["state"] ?? "")" }
        await #expect(throws: GoogleOAuthError.denied("access_denied")) {
            try await oauth(FakeTransport([])).signIn(browser: browser, receiver: receiver)
        }
    }

    @Test func grantWithoutDriveAppDataIsRefused() async throws {
        let json = #"{"access_token":"at","expires_in":3599,"refresh_token":"rt","scope":"openid email"}"#
        let receiver = FakeReceiver()
        let browser = FakeBrowser(receiver: receiver) { q in "code=c&state=\(q["state"] ?? "")" }
        await #expect(throws: GoogleOAuthError.scopeNotGranted) {
            try await oauth(FakeTransport([.init(200, json)])).signIn(browser: browser, receiver: receiver)
        }
    }

    @Test func publicClientSendsNoSecret() async throws {
        let t = FakeTransport([.init(200, Self.tokenJSON)])
        let o = GoogleDesktopOAuth(config: GoogleOAuthConfig(clientID: "id"), transport: t, now: { Self.t0 })
        _ = try await o.refresh(refreshToken: "rt-1")
        #expect(Self.form(try #require(await t.sent.first))["client_secret"] == nil)
    }

    // MARK: refresh

    @Test func refreshKeepsTheRefreshTokenWhenNoneComesBack() async throws {
        let t = FakeTransport([.init(200, #"{"access_token":"at-2","expires_in":3599}"#)])
        let tokens = try await oauth(t).refresh(refreshToken: "rt-1")
        #expect(tokens.accessToken == "at-2")
        #expect(tokens.refreshToken == "rt-1")
        let form = Self.form(try #require(await t.sent.first))
        #expect(form["grant_type"] == "refresh_token")
        #expect(form["refresh_token"] == "rt-1")
    }

    @Test func revokedRefreshTokenNeedsSignIn() async throws {
        let t = FakeTransport([.init(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)])
        await #expect(throws: GoogleOAuthError.needsSignIn) { try await oauth(t).refresh(refreshToken: "rt-1") }
    }

    @Test func serverErrorsCarryTheStatus() async throws {
        let t = FakeTransport([.init(503, "unavailable")])
        await #expect(throws: GoogleOAuthError.http(status: 503, message: "")) { try await oauth(t).refresh(refreshToken: "rt") }
    }
}

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@Suite struct GoogleTokenManagerTests {
    static let t0 = GoogleOAuthTests.t0

    func manager(_ t: FakeTransport, secrets: MemorySecretStore, clock: TestClock) -> GoogleTokenManager {
        let oauth = GoogleDesktopOAuth(config: GoogleOAuthTests.config, transport: t, now: { clock.now })
        return GoogleTokenManager(oauth: oauth, secrets: secrets, now: { clock.now })
    }

    func signedIn(_ secrets: MemorySecretStore, expiresIn: TimeInterval) async throws {
        let tokens = OAuthTokens(accessToken: "at-0", refreshToken: "rt-0", expiresAt: Self.t0.addingTimeInterval(expiresIn),
                                 scope: GoogleOAuthConfig.driveAppDataScope)
        try await secrets.write(try JSONEncoder().encode(tokens), account: GoogleTokenManager.account)
    }

    @Test func notSignedInIsReported() async throws {
        let m = manager(FakeTransport([]), secrets: MemorySecretStore(), clock: TestClock(Self.t0))
        await #expect(throws: GoogleOAuthError.needsSignIn) { try await m.accessToken() }
        #expect(await !m.isSignedIn())
    }

    @Test func freshTokenIsUsedAsIs() async throws {
        let secrets = MemorySecretStore()
        try await signedIn(secrets, expiresIn: 3000)
        let t = FakeTransport([])
        #expect(try await manager(t, secrets: secrets, clock: TestClock(Self.t0)).accessToken() == "at-0")
        #expect(await t.sent.isEmpty)
    }

    @Test func expiringTokenIsRefreshedOnceForConcurrentCallersAndStored() async throws {
        let secrets = MemorySecretStore()
        try await signedIn(secrets, expiresIn: 30)   // inside the refresh margin
        let t = FakeTransport([.init(200, #"{"access_token":"at-1","expires_in":3599}"#)])
        let m = manager(t, secrets: secrets, clock: TestClock(Self.t0))
        async let a = m.accessToken()
        async let b = m.accessToken()
        let (x, y) = try await (a, b)
        #expect(x == "at-1" && y == "at-1")
        #expect(await t.sent.count == 1)
        let stored = try JSONDecoder().decode(OAuthTokens.self, from: try #require(try await secrets.read(account: GoogleTokenManager.account)))
        #expect(stored.accessToken == "at-1")
        #expect(stored.refreshToken == "rt-0")
    }

    @Test func driveStoreUsesTheManagersToken() async throws {
        let secrets = MemorySecretStore()
        try await signedIn(secrets, expiresIn: 3000)
        let m = manager(FakeTransport([]), secrets: secrets, clock: TestClock(Self.t0))
        let drive = FakeTransport([.init(200, #"{"files":[]}"#)])
        let store = GoogleDriveVaultStore(transport: drive, accessToken: { try await m.accessToken() })
        _ = try await store.load()
        #expect(await drive.sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at-0")
    }

    @Test func signInStoresTheTokens() async throws {
        let secrets = MemorySecretStore()
        let t = FakeTransport([.init(200, GoogleOAuthTests.tokenJSON)])
        let m = manager(t, secrets: secrets, clock: TestClock(Self.t0))
        let receiver = FakeReceiver()
        let browser = FakeBrowser(receiver: receiver) { q in "code=c&state=\(q["state"] ?? "")" }
        try await m.signIn(browser: browser, receiver: receiver)
        #expect(try await m.accessToken() == "at-1")
        #expect(await m.isSignedIn())
    }

    @Test func signOutRevokesAndForgets() async throws {
        let secrets = MemorySecretStore()
        try await signedIn(secrets, expiresIn: 3000)
        let t = FakeTransport([.init(200, "{}")])
        let m = manager(t, secrets: secrets, clock: TestClock(Self.t0))
        try await m.signOut()
        let revoke = try #require(await t.sent.first)
        #expect(revoke.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(GoogleOAuthTests.form(revoke)["token"] == "rt-0")
        #expect(try await secrets.read(account: GoogleTokenManager.account) == nil)
    }

    @Test func revokedGrantForgetsTheTokens() async throws {
        let secrets = MemorySecretStore()
        try await signedIn(secrets, expiresIn: 0)
        let t = FakeTransport([.init(400, #"{"error":"invalid_grant"}"#)])
        let m = manager(t, secrets: secrets, clock: TestClock(Self.t0))
        await #expect(throws: GoogleOAuthError.needsSignIn) { try await m.accessToken() }
        #expect(try await secrets.read(account: GoogleTokenManager.account) == nil)
    }
}

#if os(Linux) || os(macOS)
@Suite struct LoopbackRedirectReceiverTests {
    @Test func receivesTheRedirectAndAnswersTheBrowser() async throws {
        let receiver = try LoopbackRedirectReceiver()
        defer { receiver.close() }
        #expect(receiver.redirectURI.hasPrefix("http://127.0.0.1:"))
        async let redirected = receiver.waitForRedirect(timeout: 10)
        // A browser asking for the favicon first must not end the wait.
        let (_, icon) = try await URLSession.shared.data(from: URL(string: "\(receiver.redirectURI)/favicon.ico")!)
        #expect((icon as? HTTPURLResponse)?.statusCode == 404)
        let (body, page) = try await URLSession.shared.data(from: URL(string: "\(receiver.redirectURI)/?code=abc&state=xyz")!)
        #expect((page as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("rSshTerm"))
        let url = try await redirected
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.first(where: { $0.name == "code" })?.value == "abc")
        #expect(q.first(where: { $0.name == "state" })?.value == "xyz")
    }

    @Test func givesUpAfterTheTimeout() async throws {
        let receiver = try LoopbackRedirectReceiver()
        defer { receiver.close() }
        await #expect(throws: GoogleOAuthError.timedOut) { try await receiver.waitForRedirect(timeout: 0.3) }
    }
}
#endif
