import Foundation

/// Picks where a desktop (Linux) keeps its secrets: the Secret Service when `secret-tool` answers, else an owner-only
/// file with a warning the app must show.
public enum DesktopSecretStore {
    public struct Choice: Sendable {
        public let store: any SecretStore
        /// Shown to the user when secrets are not in a keyring; nil when they are.
        public let warning: String?
    }

    public static func select(runner: any CommandRunner,
                              environment: [String: String] = ProcessInfo.processInfo.environment) async -> Choice {
        let keyring = SecretToolStore(runner: runner)
        if await keyring.isAvailable() { return Choice(store: keyring, warning: nil) }
        let directory = FileSecretStore.defaultDirectory(environment: environment)
        return Choice(store: FileSecretStore(directory: directory), warning: """
            No keyring (Secret Service) answered, so rSshTerm keeps this device's key and your Google sign-in in \
            \(directory.path), readable only by you but not encrypted. Install and unlock a keyring (GNOME Keyring or \
            KWallet) and secret-tool (package libsecret-tools) to keep them there instead.
            """)
    }
}
