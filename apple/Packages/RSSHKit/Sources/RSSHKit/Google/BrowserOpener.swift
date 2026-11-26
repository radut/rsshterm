import Foundation

/// Opens the consent page in the user's browser.
public protocol BrowserOpener: Sendable {
    func open(_ url: URL) async throws
}

/// Where Google's redirect lands: a loopback listener on the desktop.
public protocol RedirectReceiver: Sendable {
    /// What goes into `redirect_uri`, e.g. `http://127.0.0.1:53817`.
    var redirectURI: String { get }
    /// The full redirect URL (with `code`/`error` and `state`); throws `GoogleOAuthError.timedOut`.
    func waitForRedirect(timeout: TimeInterval) async throws -> URL
    func close()
}

/// `xdg-open` on Linux, `open` on macOS, run without a shell.
public struct SystemBrowserOpener: BrowserOpener {
    private let runner: any CommandRunner
    private let command: String

    public init(runner: any CommandRunner, command: String? = nil) {
        self.runner = runner
        #if os(macOS)
        self.command = command ?? "open"
        #else
        self.command = command ?? "xdg-open"
        #endif
    }

    public func open(_ url: URL) async throws {
        guard url.scheme == "https" else { throw GoogleOAuthError.browser("Only https pages are opened.") }
        let result = try await runner.run(command, arguments: [url.absoluteString], stdin: nil)
        guard result.status == 0 else {
            throw GoogleOAuthError.browser(result.stderrText.isEmpty ? "\(command) exited with \(result.status)." : result.stderrText)
        }
    }
}
