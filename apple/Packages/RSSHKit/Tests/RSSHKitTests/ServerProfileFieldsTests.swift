import Foundation
import Testing
@testable import RSSHKit

/// Tags, notes and the per-server font (desktop server editor): stored in the vault, carried by the editor's draft,
/// absent in older vaults, matched by the server search.
@Suite struct ServerProfileFieldsTests {
    @Test func roundTripsAndOlderVaultsDecodeEmpty() throws {
        var server = Server(name: "web", host: "web.example", username: "deploy")
        server.tags = ["prod", "eu"]
        server.notes = "Restart nginx after deploys."
        server.fontFamily = "JetBrains Mono"
        server.fontSize = 15
        let data = try JSONEncoder().encode(server)
        #expect(try JSONDecoder().decode(Server.self, from: data) == server)

        let old = Data(#"{"id":"\#(UUID().uuidString)","name":"a","host":"h","port":22,"username":"u"}"#.utf8)
        let decoded = try JSONDecoder().decode(Server.self, from: old)
        #expect(decoded.tags.isEmpty && decoded.notes == nil && decoded.fontFamily == nil && decoded.fontSize == nil)
        // Empty fields are not written, so vaults of servers without them stay as they were.
        let plain = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!plain.contains("tags") && !plain.contains("notes") && !plain.contains("font"))
    }

    @Test func badValuesFromANewerBuildAreIgnored() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"a","host":"h","port":22,"username":"u","tags":7,"fontSize":"big"}"#
        let decoded = try JSONDecoder().decode(Server.self, from: Data(json.utf8))
        #expect(decoded.tags.isEmpty && decoded.fontSize == nil)
    }

    @Test func draftCarriesAndCleansThem() throws {
        var server = Server(name: "web", host: "web.example", username: "deploy")
        server.tags = ["prod"]
        server.notes = "n"
        server.fontFamily = "Menlo"
        server.fontSize = 13
        var draft = ServerDraft(server: server)
        #expect(try draft.makeServer(id: server.id) == server)

        draft.tags = [" prod ", "Prod", "", "eu"]
        draft.notes = "   "
        draft.fontSize = 99
        let saved = try draft.makeServer(id: server.id)
        #expect(saved.tags == ["prod", "eu"])
        #expect(saved.notes == nil)
        #expect(saved.fontSize == TerminalPreferences.fontSizeRange.upperBound)
    }

    @Test func searchMatchesTagsAndNotes() {
        var a = Server(name: "alpha", host: "10.0.0.1", username: "u")
        a.tags = ["database"]
        var b = Server(name: "beta", host: "10.0.0.2", username: "u")
        b.notes = "the backup box"
        let vault = Vault(servers: [a, b])
        #expect(vault.searchingServers("datab").map(\.name) == ["alpha"])
        #expect(vault.searchingServers("backup").map(\.name) == ["beta"])
    }
}

/// Duplicate server (iOS swipe/context menu, desktop sidebar): same address, login and settings, a free "copy" name,
/// right after the original in its folder, no kept daemon sessions.
@Suite struct DuplicateServerTests {
    @Test func copyLandsAfterTheOriginalWithAFreeName() throws {
        let folder = ServerGroup(name: "Lab")
        var original = Server(name: "web", host: "web.example.com", username: "deploy", groupID: folder.id)
        original.tags = ["prod"]
        original.keptSessions = [KeptSession(id: "s1", name: "main", lastSeen: Date(timeIntervalSince1970: 0))]
        original.lastSessionBackend = "tmux"
        let other = Server(name: "db", host: "db.example.com", username: "deploy", groupID: folder.id)
        let vault = Vault(groups: [folder], servers: [original, other])

        let (once, copy) = try vault.duplicatingServer(original.id)
        #expect(copy.name == "web copy" && copy.id != original.id && copy.tags == ["prod"])
        #expect(copy.keptSessions.isEmpty && copy.lastSessionBackend == nil)
        #expect(once.servers(inGroup: folder.id).map(\.name) == ["web", "web copy", "db"])
        let (twice, second) = try once.duplicatingServer(original.id)
        #expect(second.name == "web copy 2")
        #expect(twice.servers(inGroup: folder.id).map(\.name) == ["web", "web copy 2", "web copy", "db"])
        #expect(throws: VaultEditError.unknownServer) { try vault.duplicatingServer(UUID()) }
    }
}

@Suite struct ServerFontTests {
    @Test func serverFontOverridesTheDefaultOnlyWhereSet() {
        let base = TerminalPreferences()
        var server = Server(name: "a", host: "a.example.com", username: "you")
        #expect(base.forServer(nil) == base && base.forServer(server) == base)
        server.fontFamily = "Menlo"
        #expect(base.forServer(server).fontFamily == "Menlo" && base.forServer(server).fontSize == base.fontSize)
        server.fontSize = 400
        #expect(base.forServer(server).fontSize == TerminalPreferences.fontSizeRange.upperBound)
    }
}
