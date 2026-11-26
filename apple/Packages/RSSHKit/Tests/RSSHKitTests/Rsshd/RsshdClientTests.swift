import Foundation
import Testing
@testable import RSSHKit

/// A daemon on the other end of a pipe: records the request lines, answers when the test says so.
final class FakeRsshdPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var sentLines: [[String: Any]] = []
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    /// Answers each request as it is sent; nil leaves it to the test.
    var autoReply: (@Sendable (_ op: String, _ id: Int, _ args: [String: Any]) -> String?)?

    init(autoReply: (@Sendable (String, Int, [String: Any]) -> String?)? = nil) {
        (incoming, continuation) = AsyncThrowingStream.makeStream()
        self.autoReply = autoReply
    }

    var sent: [[String: Any]] { lock.withLock { sentLines } }
    var ops: [String] { sent.compactMap { $0["op"] as? String } }

    func send(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.withLock { sentLines.append(object) }
        let op = object["op"] as? String ?? ""
        let id = object["id"] as? Int ?? 0
        if let reply = autoReply?(op, id, object["args"] as? [String: Any] ?? [:]) { push(reply) }
    }

    func push(_ line: String) { continuation.yield(Array((line + "\n").utf8)) }
    func close(throwing error: (any Error)? = nil) { continuation.finish(throwing: error) }

    func client() -> RsshdClient {
        RsshdClient(send: { [self] in send($0) }, incoming: incoming)
    }
}

@Suite struct RsshdClientTests {
    @Test func repliesMatchRequestsOutOfOrder() async throws {
        let pipe = FakeRsshdPipe()
        let client = pipe.client()
        async let first = client.status(id: "aaaa")
        async let second = client.status(id: "bbbb")
        try await waitFor { pipe.sent.count == 2 }
        let ids = pipe.sent.compactMap { $0["id"] as? Int }
        let byArg = Dictionary(uniqueKeysWithValues: pipe.sent.map {
            (($0["args"] as? [String: Any])?["id"] as? String ?? "", $0["id"] as? Int ?? 0)
        })
        #expect(Set(ids).count == 2)
        pipe.push(#"{"v":1,"id":\#(byArg["bbbb"]!),"ok":true,"result":{"session":{"id":"bbbb","name":"two","backend":"tmux"}}}"#)
        pipe.push(#"{"v":1,"id":\#(byArg["aaaa"]!),"ok":true,"result":{"session":{"id":"aaaa","name":"one","backend":"tmux"}}}"#)
        let (a, b) = try await (first, second)
        #expect(a.name == "one" && b.name == "two")
    }

    @Test func errorReplyThrowsTheCode() async throws {
        let pipe = FakeRsshdPipe { _, id, _ in
            #"{"v":1,"id":\#(id),"ok":false,"error":{"code":"not_found","message":"no session x"}}"#
        }
        let client = pipe.client()
        await #expect(throws: RsshdClientError.server(RsshdError(code: .notFound, message: "no session x"))) {
            _ = try await client.status(id: "abcd")
        }
    }

    @Test func eventsAreIgnoredWithoutSubscribe() async throws {
        let pipe = FakeRsshdPipe()
        let client = pipe.client()
        async let health = client.health()
        try await waitFor { pipe.sent.count == 1 }
        let id = pipe.sent[0]["id"] as? Int ?? 0
        pipe.push(#"{"v":1,"event":"closed","data":{"id":"ab","reason":"idle"}}"#)
        pipe.push(#"{"v":1,"id":\#(id),"ok":true,"result":{"version":"1.0.0","uptime_s":1,"backend":{"name":"tmux","version":"3.4","server_pid":1},"sessions":0,"last_error":""}}"#)
        #expect(try await health.version == "1.0.0")
    }

    @Test func closedPipeFailsPendingCallsWithItsError() async throws {
        struct Exit127: Error, Equatable {}
        let pipe = FakeRsshdPipe()
        let client = pipe.client()
        async let hello = client.hello()
        try await waitFor { pipe.sent.count == 1 }
        pipe.close(throwing: Exit127())
        do {
            _ = try await hello
            Issue.record("hello returned")
        } catch let RsshdClientError.closed(reason) {
            #expect(reason is Exit127)
        }
    }

    @Test func noAnswerTimesOut() async throws {
        let pipe = FakeRsshdPipe()
        let client = RsshdClient(send: { pipe.send($0) }, incoming: pipe.incoming, timeout: .milliseconds(50))
        await #expect(throws: RsshdClientError.timedOut) { _ = try await client.hello() }
    }

    @Test func helloSendsClientAndProto() async throws {
        let pipe = FakeRsshdPipe { _, id, _ in
            #"{"v":1,"id":\#(id),"ok":true,"result":{"proto":1,"version":"1.0.0","backends":{"tmux":"3.4"},"default_backend":"tmux","caps":{"os":"linux"},"missing":[]}}"#
        }
        let hello = try await pipe.client().hello()
        #expect(hello.version == "1.0.0")
        let args = try #require(pipe.sent.first?["args"] as? [String: Any])
        #expect((args["client"] as? String)?.hasPrefix("rSshTerm/") == true)
        #expect(args["proto"] as? [Int] == [1])
    }

    @Test func oversizedLineClosesTheClient() async throws {
        let pipe = FakeRsshdPipe()
        let client = pipe.client()
        async let hello = client.hello()
        try await waitFor { pipe.sent.count == 1 }
        pipe.push(String(repeating: "x", count: RsshdProtocol.maxLineBytes + 10))
        let result: RsshdHello? = try? await hello
        #expect(result == nil)
    }
}

/// Polls `condition` for up to two seconds.
func waitFor(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}
