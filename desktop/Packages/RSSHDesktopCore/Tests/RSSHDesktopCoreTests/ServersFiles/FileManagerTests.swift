import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@MainActor @Suite(.serialized) struct FileBrowserModelTests {
    @Test func listsSortsFiltersAndNavigates() async throws {
        let (commander, _, _) = await memoryCommander()
        let pane = commander.left
        #expect(pane.path == FilePath("/docs"))
        #expect(pane.visibleItems.map(\.name) == ["sub", "big.bin", "readme.txt"])
        pane.sort(by: .size)
        #expect(pane.visibleItems.map(\.name) == ["sub", "readme.txt", "big.bin"])
        pane.sort(by: .size)
        #expect(pane.visibleItems.map(\.name) == ["sub", "big.bin", "readme.txt"])
        pane.query = "READ"
        #expect(pane.visibleItems.map(\.name) == ["readme.txt"])
        pane.query = ""

        #expect(pane.cursor == FilePath("/docs/sub"))
        pane.moveCursor(by: 1)
        pane.toggleCursorSelection()
        #expect(pane.selection == [FilePath("/docs/big.bin")] && pane.cursor == FilePath("/docs/readme.txt"))
        #expect(pane.summary.contains("1 selected"))
        pane.moveCursor(by: -5, extend: true)
        #expect(pane.selection.count == 3)

        let sub = try #require(pane.visibleItems.first)
        #expect(await pane.activate(sub) == nil)
        #expect(pane.path == FilePath("/docs/sub") && pane.back == [FilePath("/docs")])
        await pane.goBack()
        #expect(pane.path == FilePath("/docs") && pane.forward == [FilePath("/docs/sub")])
        await pane.goForward()
        await pane.goUp()
        #expect(pane.path == FilePath("/docs") && pane.cursor == FilePath("/docs/sub"))
        let file = try #require(pane.visibleItems.last)
        #expect(await pane.activate(file) == file)
    }

    @Test func folderRenameDeleteAndCleanNames() async {
        let (commander, a, _) = await memoryCommander()
        let pane = commander.left
        await pane.makeFolder(named: "new/one")
        #expect(pane.items.contains { $0.name == "new-one" && $0.isDirectory })
        let readme = pane.items.first { $0.name == "readme.txt" }!
        await pane.rename(readme, to: "notes.txt")
        #expect(await a.contents(of: FilePath("/docs/notes.txt")) == Data("hello".utf8))
        await pane.delete(pane.items.filter { $0.name == "sub" || $0.name == "notes.txt" })
        #expect(pane.items.map(\.name).sorted() == ["big.bin", "new-one"])
        #expect(FileBrowserModel.cleanName("  ..  ") == "untitled")
        await pane.delete([FileItem(path: FilePath("/docs/missing"), kind: .file)])
        #expect(pane.error != nil)
    }

    @Test func unknownHostKeyIsAskedThenPinned() async throws {
        let server = Server(name: "srv", host: "srv.example", username: "u")
        let doc = TestDocument(Vault(servers: [server]))
        let key = KnownHost(host: "srv.example", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:abc")
        let remote = MemoryFileSource(id: "srv", displayName: "srv", home: FilePath("/home/u"))
        await remote.seedDirectory(FilePath("/home/u"))
        let places = FilePlaces(document: doc, local: MemoryFileSource(), opener: { _, vault in
            guard vault.knownHosts.contains(where: { $0.fingerprint == key.fingerprint }) else {
                throw PlaceOpenError.unknownHostKey(key)
            }
            return remote
        })
        #expect(places.places == [.local, .server(server.id)] && places.title(of: .server(server.id)) == "srv")
        let pane = FileBrowserModel(place: .server(server.id), places: places)
        await pane.load()
        #expect(pane.hostKeyQuestion == key && pane.source == nil)
        await pane.answerHostKey(trust: true)
        #expect(doc.vault.knownHosts.map(\.fingerprint) == ["SHA256:abc"])
        #expect(pane.path == FilePath("/home/u") && pane.error == nil)

        let other = FileBrowserModel(place: .server(UUID()), places: places)
        await other.load()
        #expect(other.error == VaultEditError.unknownServer.errorDescription)
    }
}

@MainActor @Suite(.serialized) struct CommanderModelTests {
    @Test func copyAndMoveBetweenPanesThroughTheQueue() async throws {
        let (commander, a, b) = await memoryCommander()
        let prompts = ScriptedPrompts()
        commander.prompts = prompts
        commander.left.selection = [FilePath("/docs/readme.txt"), FilePath("/docs/big.bin")]
        let copy = try #require(await commander.transfer(.copy))
        #expect(await commander.places.transfers.waitUntilFinished(copy)?.state == .completed)
        #expect(await b.contents(of: FilePath("/in/readme.txt")) == Data("hello".utf8))
        #expect(await eventually { commander.right.items.count == 2 })

        commander.left.selection = []
        commander.left.cursor = FilePath("/docs/big.bin")
        await commander.perform(.move)
        // big.bin is already in /in from the copy: the queue asks, the answer replaces it.
        #expect(await eventually { commander.places.transfers.pendingConflict != nil })
        commander.places.transfers.answer(ConflictAnswer(.overwrite))
        #expect(await eventually { await a.contents(of: FilePath("/docs/big.bin")) == nil })
        #expect(await eventually { commander.places.transfers.transfers.count == 2 && commander.places.transfers.activeCount == 0 })
        #expect(commander.places.transfers.overallFraction == nil)
    }

    @Test func conflictsAreAskedOnceAndAnswered() async throws {
        let (commander, _, b) = await memoryCommander()
        await b.seed(FilePath("/in/readme.txt"), Data("old".utf8))
        await commander.right.refresh()
        commander.left.cursor = FilePath("/docs/readme.txt")
        let id = try #require(await commander.transfer(.copy))
        let queue = commander.places.transfers
        #expect(await eventually { queue.pendingConflict != nil })
        #expect(queue.pendingConflict?.conflict.destinationName == "readme.txt")
        queue.answer(ConflictAnswer(.overwrite))
        #expect(await queue.waitUntilFinished(id)?.state == .completed)
        #expect(await b.contents(of: FilePath("/in/readme.txt")) == Data("hello".utf8))
    }

    @Test func keysPromptsAndPaneActions() async throws {
        let (commander, a, _) = await memoryCommander()
        let prompts = ScriptedPrompts()
        commander.prompts = prompts
        await commander.perform(.switchPane)
        #expect(commander.active === commander.right)
        await commander.perform(.switchPane)

        prompts.names = ["fresh"]
        await commander.perform(.makeFolder)
        #expect(commander.left.items.contains { $0.name == "fresh" })
        commander.left.cursor = FilePath("/docs/readme.txt")
        prompts.names = ["read.md"]
        await commander.perform(.rename)
        #expect(await a.contents(of: FilePath("/docs/read.md")) != nil)

        commander.left.cursor = FilePath("/docs/read.md")
        prompts.confirmations = [false]
        await commander.perform(.delete)
        #expect(await a.contents(of: FilePath("/docs/read.md")) != nil)
        prompts.confirmations = [true]
        await commander.perform(.delete)
        #expect(await a.contents(of: FilePath("/docs/read.md")) == nil)
        #expect(prompts.asked.contains("Delete “read.md”?"))

        commander.left.cursor = FilePath("/docs/big.bin")
        await commander.perform(.view)
        #expect(prompts.viewed.map(\.name) == ["big.bin"])

        await commander.perform(.sameFolder)
        #expect(commander.right.place == .custom("a") && commander.right.path == FilePath("/docs"))
        commander.left.selection = []
        commander.left.cursor = FilePath("/docs/big.bin")
        #expect(await commander.transfer(.copy) == nil)
        #expect(commander.error == "Both panes show the same folder.")

        await commander.right.switchTo(.custom("b"), at: FilePath("/in"))
        await commander.perform(.swapPanes)
        #expect(commander.left.place == .custom("b") && commander.right.place == .custom("a"))
        await commander.show(.custom("a"), at: FilePath("/docs/sub"))
        #expect(commander.left.path == FilePath("/docs/sub") && commander.activeSide == .left)
    }

    @Test func dropFromTheOSAndBetweenPanes() async throws {
        let (commander, a, b) = await memoryCommander()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dropped.txt")
        try Data("from finder".utf8).write(to: file)
        let id = try #require(await commander.dropLocalFiles([file], onto: .right))
        #expect(await commander.places.transfers.waitUntilFinished(id)?.state == .completed)
        #expect(await b.contents(of: FilePath("/in/dropped.txt")) == Data("from finder".utf8))

        let moved = try #require(await commander.dropFromPane(commander.left.items.filter { $0.name == "readme.txt" },
                                                              from: .left, operation: .move))
        #expect(await commander.places.transfers.waitUntilFinished(moved)?.state == .completed)
        #expect(await a.contents(of: FilePath("/docs/readme.txt")) == nil)

        let staged = try await FileDragOut.urls(for: [try await b.stat(FilePath("/in/readme.txt"))], from: b, isLocal: false,
                                                stagingIn: dir.appendingPathComponent("drag"))
        #expect(try Data(contentsOf: staged[0]) == Data("hello".utf8))
        let local = try await FileDragOut.urls(for: [FileItem(path: FilePath(file.path), kind: .file)], from: b, isLocal: true)
        #expect(local == [file])
    }

    @Test func keymapsCoverTheFKeysOnBothPlatforms() {
        for platform in [Platform.macOS, .linux] {
            let map = CommanderKeymap.bindings(for: platform)
            for (key, action) in [("f5", CommanderAction.copy), ("f6", .move), ("f7", .makeFolder), ("f8", .delete)] {
                #expect(map[KeyChord(key: key, modifiers: [])] == action)
            }
            #expect(map[KeyChord(key: "f6", modifiers: .shift)] == .rename)
        }
        #expect(CommanderKeymap.bindings(for: .macOS)[KeyChord(key: "backspace", modifiers: .command)] == .delete)
        #expect(CommanderKeymap.bindings(for: .linux)[KeyChord(key: "backspace", modifiers: [])] == .goUp)
        #expect(CommanderKeymap.buttonBar.map(\.key) == ["F3", "F4", "F5", "F6", "F7", "F8"])
    }
}

@MainActor @Suite(.serialized) struct RemoteEditSessionTests {
    func setup() async throws -> (MemoryFileSource, RemoteEditSession, URL) {
        let source = MemoryFileSource(id: "srv", displayName: "srv")
        await source.seed(FilePath("/etc/app.conf"), Data("a=1\n".utf8))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-edit-\(UUID().uuidString)")
        let session = try await RemoteEditSession.start(try await source.stat(FilePath("/etc/app.conf")), on: source, in: dir)
        return (source, session, dir)
    }

    @Test func uploadsOnSaveOnlyWhenChanged() async throws {
        let (source, session, dir) = try await setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try String(contentsOf: session.localURL, encoding: .utf8) == "a=1\n")
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        await session.checkForChanges()
        #expect(session.uploads == 0 && session.state == .watching)
        try Data("a=2\n".utf8).write(to: session.localURL)
        await session.checkForChanges()
        #expect(session.uploads == 1)
        #expect(await source.contents(of: FilePath("/etc/app.conf")) == Data("a=2\n".utf8))
        if case .uploaded = session.state {} else { Issue.record("expected uploaded, got \(session.state)") }
        await session.finish()
        #expect(session.state == .finished && !FileManager.default.fileExists(atPath: session.localURL.path))
    }

    @Test func aRemoteChangeStopsAtConflict() async throws {
        let (source, session, dir) = try await setup()
        defer { try? FileManager.default.removeItem(at: dir) }
        await source.seed(FilePath("/etc/app.conf"), Data("theirs\n".utf8), modified: Date())
        try Data("mine\n".utf8).write(to: session.localURL)
        await session.checkForChanges()
        #expect(session.state == .conflict)
        await session.resolveConflict(overwrite: false)
        #expect(session.state == .watching)
        #expect(try String(contentsOf: session.localURL, encoding: .utf8) == "theirs\n")

        await source.seed(FilePath("/etc/app.conf"), Data("theirs again\n".utf8), modified: Date().addingTimeInterval(5))
        try Data("mine again\n".utf8).write(to: session.localURL)
        await session.checkForChanges()
        await session.resolveConflict(overwrite: true)
        #expect(await source.contents(of: FilePath("/etc/app.conf")) == Data("mine again\n".utf8))
    }

    @Test func commanderF4OpensRemoteCopiesAndLocalFilesInPlace() async throws {
        let (commander, a, _) = await memoryCommander()
        let prompts = ScriptedPrompts()
        commander.prompts = prompts
        var opened: [URL] = []
        commander.openInEditor = { opened.append($0) }
        commander.editDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-f4-\(UUID().uuidString)")
        commander.left.cursor = FilePath("/docs/readme.txt")
        await commander.perform(.edit)
        await commander.perform(.edit)
        #expect(commander.editSessions.count == 1 && opened.count == 2 && prompts.editingSessions.count == 2)
        let session = commander.editSessions[0]
        try Data("edited".utf8).write(to: session.localURL)
        await commander.endEditing(session)
        #expect(await a.contents(of: FilePath("/docs/readme.txt")) == Data("edited".utf8))
        #expect(commander.editSessions.isEmpty)
        try? FileManager.default.removeItem(at: commander.editDirectory)

        #expect(EditorLauncher.command(for: URL(fileURLWithPath: "/tmp/x y"), platform: .linux) == ("/usr/bin/xdg-open", ["/tmp/x y"]))
        #expect(EditorLauncher.command(for: URL(fileURLWithPath: "/tmp/x"), platform: .macOS).arguments == ["-t", "/tmp/x"])
    }
}

@Suite struct ShellDirectoryTests {
    @Test func parsesOSC7() {
        let dir = ShellDirectory.parse(osc7: "\u{1b}]7;file://web01/home/deploy/my%20app\u{07}")
        #expect(dir == ShellDirectory(host: "web01", path: FilePath("/home/deploy/my app")))
        #expect(ShellDirectory.parse(osc7: "7;file:///tmp\u{1b}\\")?.path == FilePath("/tmp"))
        #expect(ShellDirectory.parse(osc7: "7;http://x/y") == nil)
        #expect(ShellDirectory.parse(osc7: "file://host") == nil)
        #expect(ShellDirectory(host: "", path: .root).isLocal())
        #expect(ShellDirectory(host: "Laptop", path: .root).isLocal(localHostName: "laptop.local"))
        #expect(!ShellDirectory(host: "web01", path: .root).isLocal(localHostName: "laptop"))
    }
}
