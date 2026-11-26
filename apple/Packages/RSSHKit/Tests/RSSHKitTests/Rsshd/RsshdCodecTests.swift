import Foundation
import Testing
@testable import RSSHKit

/// The wire examples of rsshd/PROTOCOL.md, decoded and encoded.
@Suite struct RsshdCodecTests {
    private func line(_ text: String) -> Data { Data(text.utf8) }

    @Test func requestIsOneVersionedLine() throws {
        let data = try RsshdCodec.request(id: 7, op: "list", args: RsshdListArgs(includeForeign: true))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.hasSuffix("\n"))
        #expect(text.filter { $0 == "\n" }.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        #expect(object["id"] as? Int == 7)
        #expect(object["op"] as? String == "list")
        #expect((object["args"] as? [String: Any])?["include_foreign"] as? Bool == true)
    }

    @Test func createLeavesOutUnsetArgs() throws {
        let args = RsshdCreateArgs(backend: "tmux", cols: 120, rows: 40)
        let data = try RsshdCodec.request(id: 1, op: "create", args: args)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sent = try #require(object["args"] as? [String: Any])
        #expect(Set(sent.keys) == ["backend", "cols", "rows"])
    }

    @Test func okReplyKeepsItsResult() throws {
        let incoming = try RsshdCodec.decode(line: line(#"{"v":1,"id":7,"ok":true,"result":{"sessions":[]}}"#))
        guard case .reply(let id, .success(let result)) = incoming else { Issue.record("not a reply"); return }
        #expect(id == 7)
        let list = try RsshdCodec.decodeResult(RsshdList.self, from: result)
        #expect(list.sessions.isEmpty && list.foreign.isEmpty)
    }

    @Test func errorReplyCarriesCodeAndMessage() throws {
        let incoming = try RsshdCodec.decode(
            line: line(#"{"v":1,"id":7,"ok":false,"error":{"code":"not_found","message":"no session 3fa9c2d1"}}"#))
        #expect(incoming == .reply(id: 7, result: .failure(RsshdError(code: .notFound, message: "no session 3fa9c2d1"))))
    }

    @Test func unknownErrorCodePassesThrough() throws {
        let incoming = try RsshdCodec.decode(
            line: line(#"{"v":1,"id":2,"ok":false,"error":{"code":"no_reptyr","message":"x"}}"#))
        guard case .reply(_, .failure(let error)) = incoming else { Issue.record("not an error"); return }
        #expect(error.code.rawValue == "no_reptyr")
    }

    @Test func eventHasNoID() throws {
        let text = #"{"v":1,"event":"expiring","data":{"id":"3fa9c2d1","reason":"idle","at":"2026-11-24T14:05:00Z","fg_command":"bash"}}"#
        guard case .event(let name, _) = try RsshdCodec.decode(line: line(text)) else {
            Issue.record("not an event"); return
        }
        #expect(name == "expiring")
    }

    @Test func unknownFieldsAreIgnored() throws {
        let text = #"{"v":1,"id":3,"ok":true,"later":[1,2],"result":{"id":"ab12","extra":{"x":1},"session":{"id":"ab12","name":"","backend":"tmux","new_field":true}}}"#
        guard case .reply(_, .success(let result)) = try RsshdCodec.decode(line: line(text)) else {
            Issue.record("not a reply"); return
        }
        let created = try RsshdCodec.decodeResult(RsshdCreated.self, from: result)
        #expect(created.id == "ab12")
        #expect(created.session.backend == "tmux")
    }

    @Test func wrongVersionIsRefused() {
        #expect(throws: RsshdCodecError.unsupportedVersion(2)) {
            try RsshdCodec.decode(line: line(#"{"v":2,"id":1,"ok":true,"result":{}}"#))
        }
    }

    @Test func notJSONIsMalformed() {
        #expect(throws: RsshdCodecError.malformed) { try RsshdCodec.decode(line: line("rsshd: hello")) }
    }

    @Test func helloResultFromTheProtocol() throws {
        let text = #"""
        {"proto":1,"version":"1.2.0","backends":{"tmux":"3.4","screen":"4.09"},"default_backend":"tmux",
         "caps":{"reptyr":"0.8.0","sudo_reptyr":false,"ptrace_scope":1,"linger":true,"os":"linux"},"missing":["reptyr"]}
        """#
        let hello = try RsshdCodec.decodeResult(RsshdHello.self, from: Data(text.utf8))
        #expect(hello.version == "1.2.0")
        #expect(hello.backends == ["tmux": "3.4", "screen": "4.09"])
        #expect(hello.defaultBackend == "tmux")
        #expect(hello.caps.os == "linux")
        #expect(hello.caps.linger)
        #expect(hello.missing == ["reptyr"])
    }

    @Test func sessionFromTheProtocol() throws {
        let text = #"""
        {"id":"3fa9c2d1","name":"build","backend":"tmux","created":"2026-11-24T12:00:00Z",
         "last_activity":"2026-11-24T13:04:05.123456789Z","attached_clients":1,"state":"active",
         "deadlines":{"idle":"2026-11-24T14:05:00Z"},"timeouts":{"idle_s":3600,"hard_s":86400,"finish_work":true,
         "warn_lead_s":300},"fg_running":false,"fg_command":"bash","alt_screen":false}
        """#
        let session = try RsshdCodec.decodeResult(RsshdSession.self, from: Data(text.utf8))
        #expect(session.id == "3fa9c2d1")
        #expect(session.name == "build")
        #expect(session.attachedClients == 1)
        #expect(session.fgCommand == "bash")
        #expect(session.deadlines.idle == Date(timeIntervalSince1970: 1_795_529_100))
        #expect(session.deadlines.hard == nil)
        let activity = try #require(session.lastActivity)
        #expect(abs(activity.timeIntervalSince1970 - 1_795_525_445.123) < 0.001)
        #expect(session.timeouts?.idleS == 3600)
    }

    @Test func foreignFromTheProtocol() throws {
        let text = #"{"sessions":[],"foreign":[{"name":"main","backend":"tmux","attached_clients":0,"attach":["tmux","attach","-t","main"]}]}"#
        let list = try RsshdCodec.decodeResult(RsshdList.self, from: Data(text.utf8))
        #expect(list.foreign == [RsshdForeign(name: "main", backend: "tmux", attachedClients: 0,
                                              attach: ["tmux", "attach", "-t", "main"])])
    }

    @Test func healthResult() throws {
        let text = #"{"version":"1.0.0","uptime_s":42,"backend":{"name":"tmux","version":"3.4","server_pid":99},"sessions":2,"last_error":""}"#
        let health = try RsshdCodec.decodeResult(RsshdHealth.self, from: Data(text.utf8))
        #expect(health.uptimeS == 42 && health.sessions == 2 && health.backend.version == "3.4")
    }
}

@Suite struct RsshdLineBufferTests {
    @Test func splitsOnNewlineAndKeepsTheRest() throws {
        var buffer = RsshdLineBuffer()
        #expect(try buffer.append(Array("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(try buffer.append(Array(":2}\n".utf8)) == [Data("{\"b\":2}".utf8)])
    }

    @Test func skipsBlankLinesAndCarriageReturns() throws {
        var buffer = RsshdLineBuffer()
        #expect(try buffer.append(Array("\n{}\r\n".utf8)) == [Data("{}".utf8)])
    }

    @Test func refusesALineOverOneMebibyte() {
        var buffer = RsshdLineBuffer()
        let chunk = [UInt8](repeating: 0x61, count: RsshdProtocol.maxLineBytes + 1)
        #expect(throws: RsshdCodecError.lineTooLong) { try buffer.append(chunk) }
    }
}
