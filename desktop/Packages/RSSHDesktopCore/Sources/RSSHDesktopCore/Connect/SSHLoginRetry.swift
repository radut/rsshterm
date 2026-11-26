import Foundation
import RSSHKit

/// Why an ssh pane's OpenSSH ended, from its exit code and the pane's last lines of text.
public enum SSHExitDiagnosis {
    /// How many of the last non-empty lines are read: ssh's own message is at the very end.
    static let tailLines = 8

    private static let refusals = ["Permission denied (", "Too many authentication failures",
                                   "No more authentication methods"]
    private static let otherCauses = ["Connection refused", "Could not resolve hostname", "timed out",
                                      "Host key verification failed", "No route to host", "Connection closed by",
                                      "closed by remote host"]

    /// True when the server refused the login (ssh exits 255 and says "Permission denied (…)"), so another user, key
    /// or password may work. A network or host key failure, or anything a shell printed earlier, is not.
    public static func refusedLogin(exitCode: Int32, output: String) -> Bool {
        guard exitCode == 255 else { return false }
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(tailLines)
        guard let last = lines.last, !otherCauses.contains(where: last.contains) else { return false }
        return lines.contains { line in refusals.contains(where: line.contains) }
    }
}

/// "Try another login…" on a desktop ssh pane: the same `ssh <alias>` with another user and login on the command
/// line (it wins over the generated Host block), and a LocalCommand that touches `markerFile` once logged in, so the
/// app knows the login worked (ssh runs it only after authentication).
public struct SSHLoginOverride: Hashable, Sendable {
    public enum Login: Hashable, Sendable {
        /// A vault key, offered first through the built-in agent by its public half.
        case key(credentialID: UUID, label: String, publicKeyFile: String)
        /// A password typed into ssh's own prompt in the terminal (keys are not offered).
        case askPassword
    }

    public var username: String
    public var login: Login
    public var markerFile: String

    public init(username: String, login: Login, markerFile: String) {
        self.username = username
        self.login = login
        self.markerFile = markerFile
    }

    /// The options that go before the alias.
    public var arguments: [String] {
        var args = ["-l", username]
        switch login {
        case .key(_, _, let file):
            args += ["-o", "IdentityFile=\(file)", "-o", "IdentitiesOnly=yes"]
        case .askPassword:
            args += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive,password"]
        }
        return args + ["-o", "PermitLocalCommand=yes", "-o", "LocalCommand=touch \(Self.localCommandQuoted(markerFile))"]
    }

    /// What the save offer and the vault see. A password asked by ssh is unknown here: saving stores the user only.
    public var attempt: LoginAttempt {
        switch login {
        case .key(let id, let label, _):
            LoginAttempt(username: username,
                         login: QuickLogin(label: label, secret: .privateKey(pem: "", passphrase: nil), credentialID: id))
        case .askPassword:
            LoginAttempt(username: username, login: QuickLogin(label: "password", secret: .password("")))
        }
    }

    /// A user name ssh can take after `-l`: trimmed, not empty, no spaces or control characters, not an option.
    public static func validUsername(_ text: String) -> String? {
        let user = text.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !user.hasPrefix("-"),
              !user.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return user
    }

    /// Single-quoted for the shell LocalCommand runs in, with `%` doubled (ssh expands `%` tokens in it).
    static func localCommandQuoted(_ path: String) -> String {
        ("'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'").replacingOccurrences(of: "%", with: "%%")
    }
}
