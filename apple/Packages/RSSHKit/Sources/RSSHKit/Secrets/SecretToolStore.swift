import Foundation

/// `SecretStore` on the freedesktop Secret Service (GNOME Keyring, KWallet, KeePassXC) through libsecret's
/// `secret-tool` (Debian/Ubuntu package `libsecret-tools`). Items carry the attributes `service=rsshterm` and
/// `account=<account>`; the secret is the base64 of the bytes (secret-tool handles text) and goes in on stdin, never on
/// the command line.
public struct SecretToolStore: SecretStore {
    public static let tool = "secret-tool"
    public static let service = "rsshterm"
    private let runner: any CommandRunner

    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    public func read(account: String) async throws -> Data? {
        let result = try await run(["lookup"] + Self.attributes(account), stdin: nil)
        // secret-tool exits 1 with nothing on stderr when there is no such item.
        if result.status == 1, result.stderrText.isEmpty { return nil }
        try Self.check(result)
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: text) else { throw SecretStoreError.unreadable(account) }
        return data
    }

    public func write(_ data: Data, account: String) async throws {
        let args = ["store", "--label", "rSshTerm \(account)"] + Self.attributes(account)
        try Self.check(try await run(args, stdin: Data(data.base64EncodedString().utf8)))
    }

    public func delete(account: String) async throws {
        let result = try await run(["clear"] + Self.attributes(account), stdin: nil)
        if result.status == 1, result.stderrText.isEmpty { return }
        try Self.check(result)
    }

    /// Whether the keyring answers: a lookup of an item that does not exist must end with "not found", not an error.
    func isAvailable() async -> Bool {
        guard let result = try? await runner.run(Self.tool, arguments: ["lookup", "service", Self.service,
                                                                        "account", "availability-probe"], stdin: nil)
        else { return false }
        return result.status == 0 || (result.status == 1 && result.stderrText.isEmpty)
    }

    private func run(_ arguments: [String], stdin: Data?) async throws -> CommandResult {
        try SecretAccount.validate(arguments.last ?? "")
        return try await runner.run(Self.tool, arguments: arguments, stdin: stdin)
    }

    private static func attributes(_ account: String) -> [String] { ["service", service, "account", account] }

    private static func check(_ result: CommandResult) throws {
        guard result.status != 0 else { return }
        if result.status == 127 { throw SecretStoreError.unavailable("secret-tool is not installed.") }
        let message = result.stderrText
        throw SecretStoreError.unavailable(message.isEmpty ? "secret-tool exited with \(result.status)." : message)
    }
}
