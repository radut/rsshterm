import Foundation
import Testing
@testable import RSSHKit

/// A daemon that already holds sessions `ids` (newest activity first in `ids` order).
private func daemon(holding ids: [String]) -> @Sendable (String, Int, [String: Any]) -> String? {
    { op, id, _ in
        switch op {
        case "hello":
            return #"{"v":1,"id":\#(id),"ok":true,"result":{"proto":1,"version":"1.0.2","backends":{"tmux":"3.4"},"default_backend":"tmux","caps":{"os":"linux"},"missing":[]}}"#
        case "list":
            let rows = ids.enumerated().map { index, sid in
                #"{"id":"\#(sid)","name":"s\#(index)","backend":"tmux","last_activity":"2026-11-25T1\#(9 - index):00:00Z","fg_command":"htop"}"#
            }
            return #"{"v":1,"id":\#(id),"ok":true,"result":{"sessions":[\#(rows.joined(separator: ","))],"foreign":[]}}"#
        case "create":
            return #"{"v":1,"id":\#(id),"ok":true,"result":{"id":"new1","session":{"id":"new1","backend":"tmux"}}}"#
        default:
            return nil
        }
    }
}

private actor Asked {
    var offered: [[String]] = []
    func record(_ ids: [String]) { offered.append(ids) }
}

@Suite struct RsshdResumeFlowTests {
    private func request(_ resume: ResumeChoice, openHere: Set<String> = []) -> RsshdConnectRequest {
        var request = RsshdConnectRequest(backend: .tmux, attachTo: nil, cols: 80, rows: 24)
        request.resume = resume
        request.openHere = openHere
        return request
    }

    @Test func pickerOffersOnlySessionsNotOpenHere() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(holding: ["aa", "bb", "cc"]))
        let asked = Asked()
        let outcome = await RsshdConnectFlow.run(request(.ask, openHere: ["bb"]), client: pipe.client()) { offered in
            await asked.record(offered.map(\.id))
            return .resume(["cc"])
        }
        #expect(await asked.offered == [["aa", "cc"]])
        guard case .attach(let attachment) = outcome else { Issue.record("\(outcome)"); return }
        #expect(attachment.id == "cc" && !attachment.created)
        #expect(attachment.listedIDs == ["aa", "bb", "cc"])
        #expect(pipe.ops == ["hello", "list"])
    }

    @Test func resumingSeveralAttachesTheFirstAndReturnsTheRest() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(holding: ["aa", "bb", "cc"]))
        let outcome = await RsshdConnectFlow.run(request(.ask), client: pipe.client()) { _ in .resume(["aa", "cc"]) }
        guard case .attach(let attachment) = outcome else { Issue.record("\(outcome)"); return }
        #expect(attachment.id == "aa" && attachment.alsoResume == ["cc"])
    }

    @Test func choosingNewCreates() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(holding: ["aa"]))
        let outcome = await RsshdConnectFlow.run(request(.ask), client: pipe.client()) { _ in .new }
        guard case .attach(let attachment) = outcome else { Issue.record("\(outcome)"); return }
        #expect(attachment.id == "new1" && attachment.created)
        #expect(pipe.ops == ["hello", "list", "create"])
    }

    @Test func nothingToResumeGoesStraightToANewOne() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(holding: ["bb"]))
        let asked = Asked()
        let outcome = await RsshdConnectFlow.run(request(.ask, openHere: ["bb"]), client: pipe.client()) {
            await asked.record($0.map(\.id))
            return .new
        }
        #expect(await asked.offered.isEmpty)
        guard case .attach(let attachment) = outcome else { Issue.record("\(outcome)"); return }
        #expect(attachment.created)
    }

    @Test func resumeLastSkipsTheSheetAndTakesTheNewestActivity() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(holding: ["aa", "bb"]))
        let asked = Asked()
        let outcome = await RsshdConnectFlow.run(request(.last), client: pipe.client()) {
            await asked.record($0.map(\.id))
            return .new
        }
        #expect(await asked.offered.isEmpty)
        guard case .attach(let attachment) = outcome else { Issue.record("\(outcome)"); return }
        #expect(attachment.id == "aa")
    }

    @Test func alwaysNewDoesNotList() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(holding: ["aa"]))
        _ = await RsshdConnectFlow.run(request(.new), client: pipe.client())
        #expect(pipe.ops == ["hello", "create"])
    }
}

@Suite struct KeptSessionMappingTests {
    private let now = Date(timeIntervalSince1970: 1_795_500_000)

    @Test func attachingRecordsTheSessionOnce() throws {
        let server = Server(name: "a", host: "h", username: "u")
        let first = try #require(server.recordingKept(id: "aa", name: "pi", at: now))
        #expect(first.keptSessions == [KeptSession(id: "aa", name: "pi", lastSeen: now)])
        let later = try #require(first.recordingKept(id: "aa", name: "pi", at: now.addingTimeInterval(7200)))
        #expect(later.keptSessions.count == 1 && later.keptSessions[0].lastSeen == now.addingTimeInterval(7200))
        // Seen again within the hour: no vault write.
        #expect(first.recordingKept(id: "aa", name: "pi", at: now.addingTimeInterval(60)) == nil)
    }

    @Test func renamingChangesOnlyTheName() throws {
        let server = try #require(Server(name: "a", host: "h", username: "u").recordingKept(id: "aa", name: "pi", at: now))
        let renamed = try #require(server.renamingKept(id: "aa", to: "build"))
        #expect(renamed.keptSessions == [KeptSession(id: "aa", name: "build", lastSeen: now)])
        #expect(renamed.renamingKept(id: "aa", to: "build") == nil)
    }

    @Test func staleIDsAreDroppedQuietly() throws {
        var server = Server(name: "a", host: "h", username: "u")
        server.keptSessions = [KeptSession(id: "aa", name: "x", lastSeen: now), KeptSession(id: "bb", name: "y", lastSeen: now)]
        let kept = try #require(server.keepingKept(onlyIDs: ["bb", "zz"]))
        #expect(kept.keptSessions.map(\.id) == ["bb"])
        #expect(kept.keepingKept(onlyIDs: ["bb"]) == nil)
        #expect(kept.forgettingKept(id: "bb")?.keptSessions == [])
    }

    @Test func mappingSurvivesEncodeAndDecode() throws {
        var server = Server(name: "a", host: "h", username: "u")
        server.keptSessions = [KeptSession(id: "aa", name: "x", lastSeen: now)]
        server.resumeChoice = .last
        let back = try JSONDecoder().decode(Server.self, from: JSONEncoder().encode(server))
        #expect(back.keptSessions == server.keptSessions)
        #expect(back.resumeChoice == .last)
    }

    @Test func olderVaultsDecodeEmpty() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"a","host":"h","port":22,"username":"u"}"#
        let server = try JSONDecoder().decode(Server.self, from: Data(json.utf8))
        #expect(server.keptSessions.isEmpty)
        #expect(server.resumeChoice == nil)
        #expect(server.effectiveResumeChoice == .ask)
    }
}
