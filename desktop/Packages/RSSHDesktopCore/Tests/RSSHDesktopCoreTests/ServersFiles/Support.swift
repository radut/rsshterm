import Foundation
import Observation
import RSSHKit
@testable import RSSHDesktopCore

/// A vault document that keeps commits in memory and can be told to fail the next save.
@MainActor @Observable
final class TestDocument: VaultDocument {
    private(set) var vault: Vault
    private(set) var commits = 0
    var failNextSave = false

    init(_ vault: Vault = Vault()) { self.vault = vault }

    func commit(_ vault: Vault) async throws {
        self.vault = vault
        commits += 1
        if failNextSave {
            failNextSave = false
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

/// Throwaway ed25519 key made with ssh-keygen for tests only; it logs in nowhere.
let testKeyPEM = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBD/YrMcEYGJGPCrh3O4/HbqYpUw+NEm0KoKNTSrrfGhwAAAJC6L3P2ui9z
9gAAAAtzc2gtZWQyNTUxOQAAACBD/YrMcEYGJGPCrh3O4/HbqYpUw+NEm0KoKNTSrrfGhw
AAAECqPx5gM/rogOd9+T+jSi59J3hegXuobHpBUX9cUDVA50P9isxwRgYkY8KuHc7j8dup
ilTD40SbQqgo1NKut8aHAAAADHRlc3RAcnNzaGtpdAE=
-----END OPENSSH PRIVATE KEY-----
"""

/// Two memory sources registered as places "a" and "b", and a commander over them.
@MainActor
func memoryCommander() async -> (CommanderModel, MemoryFileSource, MemoryFileSource) {
    let a = MemoryFileSource(id: "a", displayName: "A")
    let b = MemoryFileSource(id: "b", displayName: "B")
    await a.seed(FilePath("/docs/readme.txt"), Data("hello".utf8))
    await a.seed(FilePath("/docs/big.bin"), Data(repeating: 7, count: 1000))
    await a.seedDirectory(FilePath("/docs/sub"))
    await b.seedDirectory(FilePath("/in"))
    let places = FilePlaces(document: TestDocument(), local: MemoryFileSource(id: "local", displayName: "Local"))
    places.register(a, title: "A", for: "a")
    places.register(b, title: "B", for: "b")
    let commander = CommanderModel(places: places, left: .custom("a"), right: .custom("b"),
                                   leftStart: FilePath("/docs"), rightStart: FilePath("/in"))
    await commander.load()
    return (commander, a, b)
}

/// Answers the commander's questions from a script.
@MainActor
final class ScriptedPrompts: CommanderPrompts {
    var names: [String?] = []
    var confirmations: [Bool] = []
    private(set) var asked: [String] = []
    private(set) var viewed: [FileItem] = []
    private(set) var editingSessions: [RemoteEditSession] = []

    func askName(title: String, initial: String) async -> String? {
        asked.append(title)
        return names.isEmpty ? nil : names.removeFirst()
    }

    func confirm(_ message: String, destructive: Bool) async -> Bool {
        asked.append(message)
        return confirmations.isEmpty ? false : confirmations.removeFirst()
    }

    func view(_ item: FileItem, in pane: FileBrowserModel) { viewed.append(item) }
    func editing(_ session: RemoteEditSession) { editingSessions.append(session) }
}

/// Polls `condition` on the main actor for up to `seconds`.
@MainActor
func eventually(_ seconds: Double = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
