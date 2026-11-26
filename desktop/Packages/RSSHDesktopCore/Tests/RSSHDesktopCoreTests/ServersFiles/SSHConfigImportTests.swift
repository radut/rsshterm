import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@Suite struct SSHConfigParserTests {
    let config = """
    # personal
    Include ~/.config/rssh/ssh_config
    Include conf.d/*

    Host web web-alias
        HostName web.example.com
        User deploy
        Port 2222
        IdentityFile ~/.ssh/id_web
        ForwardAgent yes

    Host db
      hostname=198.51.100.5
      ProxyJump bastion
      Port "70000"

    Host "quoted name"
        HostName q.example

    Host *.internal !skip.internal
        User ops

    Host app.internal skip.internal
        Port 2200

    Match host foo
        User nobody

    Host *
        User fallback
        IdentityFile ~/.ssh/id_default
        Port 22
    """

    @Test func readsHostsWithFirstValueWins() throws {
        let result = SSHConfigParser.parse(config)
        #expect(result.entries.map(\.alias) == ["web", "web-alias", "db", "quoted name", "app.internal", "skip.internal"])
        let web = try #require(result.entries.first)
        #expect(web.host == "web.example.com" && web.user == "deploy" && web.port == 2222)
        #expect(web.identityFiles == ["~/.ssh/id_web", "~/.ssh/id_default"])
        #expect(web.forwardAgent == true)
        let db = result.entries[2]
        #expect(db.host == "198.51.100.5" && db.proxyJump == "bastion" && db.user == "fallback")
        // The bad port is noted and the next block's port is taken.
        #expect(db.port == 22)
        #expect(result.notes.contains { $0.contains("70000") })
        #expect(result.entries[3].host == "q.example")
        // Wildcards with negation: app.internal gets ops, skip.internal does not.
        #expect(result.entries[4].user == "ops" && result.entries[4].port == 2200)
        #expect(result.entries[5].user == "fallback")
        #expect(result.includes == ["conf.d/*"])
        #expect(result.notes.contains { $0.contains("Match") })
    }

    @Test func globAndKeywordForms() {
        #expect(SSHConfigParser.glob("*.example.com", "a.EXAMPLE.com"))
        #expect(SSHConfigParser.glob("198.51.100.?", "198.51.100.7"))
        #expect(!SSHConfigParser.glob("198.51.100.?", "198.51.100.17"))
        #expect(SSHConfigParser.keywordAndValue("  Port = 22 ")! == ("port", "22"))
        #expect(SSHConfigParser.keywordAndValue("# comment") == nil)
        #expect(SSHConfigParser.words(#"a "b c" d"#) == ["a", "b c", "d"])
    }

    @Test func candidatesFlagDuplicatesAndProblems() {
        let existing = Server(name: "old", host: "web.example.com", port: 2222, username: "deploy")
        let vault = Vault(servers: [existing])
        let result = SSHConfigParser.parse("Host web\n HostName web.example.com\n User deploy\n Port 2222\nHost nouser\nHost bad\n HostName \"a b\"\n User x")
        let candidates = SSHConfigImport.candidates(result, vault: vault, defaultUser: nil)
        #expect(candidates[0].existing == existing.id)
        #expect(candidates[1].problem == ServerDraft.Field.username.message)
        #expect(candidates[2].problem == ServerDraft.Field.host.message)
        let withDefault = SSHConfigImport.candidates(result, vault: vault, defaultUser: "me")
        #expect(withDefault[1].isImportable && withDefault[1].draft.username == "me")
    }
}
