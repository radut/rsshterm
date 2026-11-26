import Foundation
import Testing
@testable import RSSHKit

/// Answers each command with the next scripted result and records what was run.
actor FakeCommandRunner: CommandRunner {
    private var results: [CommandResult]
    private(set) var calls: [(command: String, arguments: [String], stdin: Data?)] = []

    init(_ results: [CommandResult]) { self.results = results }

    func run(_ command: String, arguments: [String], stdin: Data?) async throws -> CommandResult {
        calls.append((command, arguments, stdin))
        guard !results.isEmpty else { return CommandResult(status: 127, stdout: Data(), stderr: Data()) }
        return results.removeFirst()
    }
}

extension CommandResult {
    static func ok(_ out: String = "") -> CommandResult { CommandResult(status: 0, stdout: Data(out.utf8), stderr: Data()) }
    static func status(_ s: Int32, _ err: String = "") -> CommandResult {
        CommandResult(status: s, stdout: Data(), stderr: Data(err.utf8))
    }
}

@Suite struct SecretToolStoreTests {
    @Test func writeStoresBase64OnStdinWithServiceAndAccount() async throws {
        let r = FakeCommandRunner([.ok()])
        try await SecretToolStore(runner: r).write(Data([0, 1, 2, 255]), account: "device-key")
        let call = try #require(await r.calls.first)
        #expect(call.command == "secret-tool")
        #expect(call.arguments == ["store", "--label", "rSshTerm device-key", "service", "rsshterm", "account", "device-key"])
        #expect(call.stdin == Data("AAEC/w==".utf8))
    }

    @Test func readDecodesTheSecret() async throws {
        let r = FakeCommandRunner([.ok("AAEC/w==\n")])
        #expect(try await SecretToolStore(runner: r).read(account: "device-key") == Data([0, 1, 2, 255]))
        #expect(await r.calls.first?.arguments == ["lookup", "service", "rsshterm", "account", "device-key"])
    }

    @Test func readOfMissingItemIsNil() async throws {
        let r = FakeCommandRunner([.status(1)])
        #expect(try await SecretToolStore(runner: r).read(account: "device-key") == nil)
    }

    @Test func failureWithAMessageIsAnError() async throws {
        let r = FakeCommandRunner([.status(1, "Cannot autolaunch D-Bus without X11 $DISPLAY")])
        await #expect(throws: SecretStoreError.self) { try await SecretToolStore(runner: r).read(account: "device-key") }
    }

    @Test func garbageIsAnError() async throws {
        let r = FakeCommandRunner([.ok("not base64 !!")])
        await #expect(throws: SecretStoreError.unreadable("device-key")) {
            try await SecretToolStore(runner: r).read(account: "device-key")
        }
    }

    @Test func deleteClearsTheItem() async throws {
        let r = FakeCommandRunner([.ok()])
        try await SecretToolStore(runner: r).delete(account: "device-key")
        #expect(await r.calls.first?.arguments == ["clear", "service", "rsshterm", "account", "device-key"])
    }

    @Test(arguments: ["", "a b", "../x", "x/y", "UPPER"])
    func badAccountNamesAreRefused(account: String) async {
        let r = FakeCommandRunner([])
        await #expect(throws: SecretStoreError.badAccount(account)) {
            try await SecretToolStore(runner: r).write(Data(), account: account)
        }
        #expect(await r.calls.isEmpty)
    }
}

@Suite struct FileSecretStoreTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-secrets-\(UUID().uuidString)")
    }

    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func roundTripWithOwnerOnlyPermissions() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecretStore(directory: root)
        #expect(try await store.read(account: "google-oauth") == nil)
        try await store.write(Data("one".utf8), account: "google-oauth")
        try await store.write(Data("two".utf8), account: "google-oauth")
        #expect(try await store.read(account: "google-oauth") == Data("two".utf8))
        #expect(try mode(root) == 0o700)
        #expect(try mode(root.appendingPathComponent("google-oauth")) == 0o600)
        try await store.delete(account: "google-oauth")
        #expect(try await store.read(account: "google-oauth") == nil)
        try await store.delete(account: "google-oauth")   // deleting nothing is fine
    }

    @Test func fileOthersCanReadIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecretStore(directory: root)
        try await store.write(Data("x".utf8), account: "device-key")
        let file = root.appendingPathComponent("device-key")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        await #expect(throws: SecretStoreError.insecurePermissions(file.path)) { try await store.read(account: "device-key") }
    }

    @Test func directoryFollowsXDGDataHome() {
        #expect(FileSecretStore.defaultDirectory(environment: ["XDG_DATA_HOME": "/data", "HOME": "/home/u"]).path
                == "/data/rssh/secrets")
        #expect(FileSecretStore.defaultDirectory(environment: ["HOME": "/home/u"]).path == "/home/u/.local/share/rssh/secrets")
        #expect(FileSecretStore.defaultDirectory(environment: ["XDG_DATA_HOME": "relative", "HOME": "/home/u"]).path
                == "/home/u/.local/share/rssh/secrets")
    }
}

@Suite struct DesktopSecretStoreSelectionTests {
    @Test func secretServiceWhenSecretToolAnswers() async {
        let r = FakeCommandRunner([.status(1)])   // probe: lookup of an item that is not there
        let choice = await DesktopSecretStore.select(runner: r, environment: ["HOME": "/home/u"])
        #expect(choice.store is SecretToolStore)
        #expect(choice.warning == nil)
    }

    @Test func fileWithAWarningWhenSecretToolIsMissing() async {
        let r = FakeCommandRunner([.status(127, "env: 'secret-tool': No such file or directory")])
        let choice = await DesktopSecretStore.select(runner: r, environment: ["HOME": "/home/u"])
        let file = choice.store as? FileSecretStore
        #expect(file?.directory.path == "/home/u/.local/share/rssh/secrets")
        let warning = choice.warning ?? ""
        #expect(warning.contains("not encrypted"))
        #expect(warning.contains("/home/u/.local/share/rssh/secrets"))
    }

    @Test func fileWithAWarningWhenTheKeyringIsUnreachable() async {
        let r = FakeCommandRunner([.status(1, "Cannot autolaunch D-Bus without X11 $DISPLAY")])
        let choice = await DesktopSecretStore.select(runner: r, environment: ["HOME": "/home/u"])
        #expect(choice.store is FileSecretStore)
        #expect(choice.warning != nil)
    }
}

@Suite struct DeviceKeyStoreTests {
    @Test func loadOrCreateMakesOneKeyAndKeepsIt() async throws {
        let store = SecretStoreDeviceKeyStore(secrets: MemorySecretStore())
        #expect(try await store.load() == nil)
        let first = try await store.loadOrCreate()
        let again = try await store.loadOrCreate()
        #expect(first == again)
        #expect(first.secret.count == 32)
        let wrapper = try first.wrapper()
        #expect(wrapper.id == "device:\(first.tag)")
        #expect(!store.requiresUserPresence)
    }

    @Test func createRefusesToReplaceAKey() async throws {
        let store = SecretStoreDeviceKeyStore(secrets: MemorySecretStore())
        _ = try await store.create()
        await #expect(throws: DeviceKeyStoreError.alreadyExists) { try await store.create() }
    }

    @Test func deleteForgetsTheKey() async throws {
        let store = SecretStoreDeviceKeyStore(secrets: MemorySecretStore())
        _ = try await store.create()
        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test func corruptItemIsAnError() async throws {
        let secrets = MemorySecretStore()
        try await secrets.write(Data("junk".utf8), account: SecretStoreDeviceKeyStore.account)
        await #expect(throws: DeviceKeyStoreError.unreadable) { try await SecretStoreDeviceKeyStore(secrets: secrets).load() }
    }

    @Test func memoryDoubleReportsUserPresence() async throws {
        let store = MemoryDeviceKeyStore(requiresUserPresence: true)
        #expect(store.requiresUserPresence)
        let m = try await store.loadOrCreate()
        #expect(try await store.load() == m)
    }

    @Test func aDeviceKeyFromTheStoreOpensTheVaultItSealed() async throws {
        let store = SecretStoreDeviceKeyStore(secrets: MemorySecretStore())
        let device = try await store.loadOrCreate().wrapper()
        let env = try await VaultCipher.makeEnvelope(Vault(), key: VaultCipher.newVaultKey(), wrappers: [device])
        let reloaded = try #require(try await store.load()).wrapper()
        guard case .opened = try await VaultOpener.open(env, wrappers: [reloaded]) else {
            Issue.record("did not open")
            return
        }
    }
}
