import Foundation
import RSSHDesktopCore

/// What the app says about an update check: nothing for a quiet background check that found nothing; a dialog
/// with the release notes when a build is available; the outcome of an install.
public enum UpdatePresenter {
    public enum Action: Equatable, Sendable {
        case install
        /// The app quits so the relaunch helper can start the new build.
        case quit
        /// Copy this command (no graphical sudo: the user pastes it in a terminal).
        case copy(String)
        case openDownloads
    }

    public struct Message: Equatable, Sendable {
        public let title: String
        public let body: String
        public let action: Action?
    }

    public static let downloadsURL = "https://rssh-ea902a.gitlab.io/desktop/"

    public static func message(for outcome: UpdateService.Outcome, manual: Bool) -> Message? {
        switch outcome {
        case .notDue:
            return nil
        case .upToDate(let latest):
            guard manual else { return nil }
            return Message(title: "rSshTerm is up to date", body: "The latest version is \(latest).", action: nil)
        case .available(let update):
            return Message(title: "rSshTerm \(update.version) is available", body: notes(update), action: .install)
        case .installed(let update, let result):
            switch result {
            case .relaunching:
                return Message(title: "rSshTerm \(update.version) is installed",
                               body: "rSshTerm restarts now to use it.", action: .quit)
            case .showCommand(let command):
                return Message(title: "rSshTerm \(update.version) is available",
                               body: notes(update) + "\n\nTo install it, run in a terminal:\n\(command)",
                               action: .copy(command))
            case .cancelled:
                return Message(title: "Update cancelled", body: "rSshTerm \(update.version) was not installed.",
                               action: nil)
            case .manual(let reason):
                return Message(title: "rSshTerm \(update.version) is available",
                               body: notes(update) + "\n\n\(reason) Download it from \(downloadsURL)",
                               action: .openDownloads)
            }
        }
    }

    /// Errors are shown only when the user asked (Help › Check for Updates); background checks stay quiet.
    public static func message(for error: UpdateError, manual: Bool) -> Message? {
        guard manual else { return nil }
        return Message(title: "Could not check for updates", body: describe(error), action: nil)
    }

    static func notes(_ update: AvailableUpdate) -> String {
        let text = update.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "A new version of rSshTerm is ready." : text
    }

    static func describe(_ error: UpdateError) -> String {
        switch error {
        case .unsigned, .badSignature: "The update information is not signed by rSshTerm, so it was ignored."
        case .badManifest(let m): "The update information could not be read (\(m))."
        case .noAsset(let key): "There is no build for this machine (\(key))."
        case .insecureURL(let url): "Refused a download that is not https: \(url)"
        case .checksumMismatch: "The download did not match its checksum; nothing was changed."
        case .transport(let m): "The update server could not be reached (\(m))."
        case .installFailed(let m): "The update could not be installed (\(m))."
        }
    }
}
