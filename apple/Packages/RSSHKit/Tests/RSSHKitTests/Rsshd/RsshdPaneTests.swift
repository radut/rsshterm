import Foundation
import Testing
@testable import RSSHKit

@Suite struct RsshdPaneTests {
    @Test func sessionDecodesPane() throws {
        let json = #"{"id":"a","pane":{"command":"vim","args":["/etc/hosts"],"cwd":"/etc"}}"#
        let session = try JSONDecoder().decode(RsshdSession.self, from: Data(json.utf8))
        #expect(session.pane == PaneReport(command: "vim", args: ["/etc/hosts"], cwd: "/etc"))
        let old = try JSONDecoder().decode(RsshdSession.self, from: Data(#"{"id":"a"}"#.utf8))
        #expect(old.pane == nil)
    }

    @Test func paneEventDecodes() throws {
        let event = RsshdEvent(name: "pane",
                               data: Data(#"{"id":"a","pane":{"command":"","args":[],"cwd":"/var/log"}}"#.utf8))
        let pane = try #require(event.pane)
        #expect(pane.id == "a")
        #expect(pane.report == PaneReport(command: "", args: [], cwd: "/var/log"))
        #expect(RsshdEvent(name: "state", data: Data(#"{"id":"a","state":"active"}"#.utf8)).pane == nil)
    }

    @Test func subscribeAsksForPaneEvents() async throws {
        let pipe = FakeRsshdPipe { _, id, _ in #"{"v":1,"id":\#(id),"ok":true,"result":{}}"# }
        let client = pipe.client()
        let stream = try await client.subscribe(pane: true)
        let args = try #require(pipe.sent.first?["args"] as? [String: Any])
        #expect(args["pane"] as? Bool == true)
        pipe.push(#"{"v":1,"event":"pane","data":{"id":"s1","pane":{"command":"htop","args":[],"cwd":"/root"}}}"#)
        var iterator = stream.makeAsyncIterator()
        let event = try #require(await iterator.next())
        #expect(event.pane?.report.command == "htop")
    }

    @Test func plainSubscribeSendsNoPaneFlag() async throws {
        let pipe = FakeRsshdPipe { _, id, _ in #"{"v":1,"id":\#(id),"ok":true,"result":{}}"# }
        _ = try await pipe.client().subscribe()
        let args = pipe.sent.first?["args"] as? [String: Any] ?? [:]
        #expect(args["pane"] == nil)
    }
}
