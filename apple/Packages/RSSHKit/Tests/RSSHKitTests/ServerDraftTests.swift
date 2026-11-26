import Foundation
import Testing
@testable import RSSHKit

@Suite struct ServerDraftTests {
    let draft = ServerDraft(name: "pi", host: "10.0.0.2", port: "22", username: "root")

    @Test func aValidDraftBecomesAServer() throws {
        let id = UUID()
        let server = try draft.makeServer(id: id)
        #expect(server == Server(id: id, name: "pi", host: "10.0.0.2", port: 22, username: "root"))
    }

    @Test func trimsAndFallsBackToTheHostForTheName() throws {
        let messy = ServerDraft(name: "  ", host: " example.org ", port: " 2222 ", username: " admin ")
        let server = try messy.makeServer(id: UUID())
        #expect(server.name == "example.org" && server.host == "example.org")
        #expect(server.port == 2222 && server.username == "admin")
    }

    @Test(arguments: ["0", "65536", "-1", "", "22a", "99999999999999999999"])
    func portOutsideRangeIsRejected(port: String) {
        var bad = draft
        bad.port = port
        #expect(bad.issues == [.port])
        #expect(throws: ServerDraftError.self) { try bad.makeServer(id: UUID()) }
    }

    @Test(arguments: ["1", "22", "65535"])
    func portInsideRangeIsAccepted(port: String) {
        var ok = draft
        ok.port = port
        #expect(ok.issues.isEmpty)
    }

    @Test(arguments: ["", "two words", "bad/host", "a\u{0}b"])
    func badHostsAreRejected(host: String) {
        var bad = draft
        bad.host = host
        #expect(bad.issues == [.host])
    }

    @Test(arguments: ["example.org", "10.0.0.2", "fe80::1", "[fe80::1%en0]", "my_host-1.local"])
    func goodHostsAreAccepted(host: String) {
        var ok = draft
        ok.host = host
        #expect(ok.issues.isEmpty)
    }

    @Test func usernameIsRequiredAndHasNoSpaces() {
        var bad = draft
        bad.username = ""
        #expect(bad.issues == [.username])
        bad.username = "a b"
        #expect(bad.issues == [.username])
    }

    @Test func everyIssueIsListedInFieldOrder() {
        let bad = ServerDraft(name: "", host: "", port: "0", username: "")
        #expect(bad.issues == [.host, .port, .username])
        #expect(throws: ServerDraftError(issues: [.host, .port, .username])) { try bad.makeServer(id: UUID()) }
    }

    @Test func aDraftOfAServerKeepsItsLinks() throws {
        let group = UUID(), credential = UUID()
        let server = Server(name: "n", host: "h", port: 2200, username: "u", credentialID: credential, groupID: group)
        let draft = ServerDraft(server: server)
        #expect(draft.port == "2200")
        #expect(try draft.makeServer(id: server.id) == server)
    }

    @Test func issuesHaveReadableMessages() {
        #expect(ServerDraft.Field.port.message.contains("65535"))
        #expect(ServerDraftError(issues: [.host]).errorDescription?.isEmpty == false)
    }
}
