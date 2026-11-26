import Foundation
import Testing
@testable import RSSHKit

/// Replies of a daemon that has tmux (and screen when asked), keyed by op.
private func daemon(screen: Bool = false, statusNotFound: Bool = false,
                    createError: String? = nil) -> @Sendable (String, Int, [String: Any]) -> String? {
    { op, id, args in
        switch op {
        case "hello":
            let backends = screen ? #"{"tmux":"3.4","screen":"4.09"}"# : #"{"tmux":"3.4"}"#
            return #"{"v":1,"id":\#(id),"ok":true,"result":{"proto":1,"version":"1.0.2","backends":\#(backends),"default_backend":"tmux","caps":{"os":"linux"},"missing":[]}}"#
        case "create":
            if let createError {
                return #"{"v":1,"id":\#(id),"ok":false,"error":{"code":"backend_error","message":"\#(createError)"}}"#
            }
            let backend = args["backend"] as? String ?? "tmux"
            return #"{"v":1,"id":\#(id),"ok":true,"result":{"id":"5e55a0b1","session":{"id":"5e55a0b1","name":"","backend":"\#(backend)"}}}"#
        case "status":
            let sid = args["id"] as? String ?? ""
            if statusNotFound {
                return #"{"v":1,"id":\#(id),"ok":false,"error":{"code":"not_found","message":"no session \#(sid)"}}"#
            }
            return #"{"v":1,"id":\#(id),"ok":true,"result":{"session":{"id":"\#(sid)","name":"","backend":"tmux"}}}"#
        default:
            return nil
        }
    }
}

@Suite struct RsshdConnectFlowTests {
    @Test func newSessionCreatesWithTheTerminalSize() async {
        let pipe = FakeRsshdPipe(autoReply: daemon())
        let outcome = await RsshdConnectFlow.run(.init(backend: .tmux, attachTo: nil, cols: 132, rows: 43),
                                                 client: pipe.client())
        guard case .attach(let attachment) = outcome else { Issue.record("\(outcome)"); return }
        #expect(attachment.id == "5e55a0b1" && attachment.created && attachment.backend == "tmux")
        #expect(attachment.hello.version == "1.0.2")
        #expect(pipe.ops == ["hello", "create"])
        let args = pipe.sent[1]["args"] as? [String: Any]
        #expect(args?["cols"] as? Int == 132 && args?["rows"] as? Int == 43 && args?["backend"] as? String == "tmux")
    }

    @Test func reconnectAsksStatusOfTheSameID() async {
        let pipe = FakeRsshdPipe(autoReply: daemon())
        let outcome = await RsshdConnectFlow.run(.init(backend: .tmux, attachTo: "5e55a0b1", cols: 80, rows: 24),
                                                 client: pipe.client())
        guard case .attach(let attachment) = outcome else { Issue.record("\(outcome)"); return }
        #expect(attachment.id == "5e55a0b1" && !attachment.created)
        #expect(pipe.ops == ["hello", "status"])
    }

    @Test func goneSessionIsReported() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(statusNotFound: true))
        let outcome = await RsshdConnectFlow.run(.init(backend: .tmux, attachTo: "5e55a0b1", cols: 80, rows: 24),
                                                 client: pipe.client())
        #expect(outcome == .sessionEnded(id: "5e55a0b1"))
    }

    @Test func screenIsPassedWhenTheServerHasIt() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(screen: true))
        let outcome = await RsshdConnectFlow.run(.init(backend: .screen, attachTo: nil, cols: 80, rows: 24),
                                                 client: pipe.client())
        guard case .attach(let attachment) = outcome else { Issue.record("\(outcome)"); return }
        #expect(attachment.backend == "screen" && attachment.note == nil)
        #expect((pipe.sent[1]["args"] as? [String: Any])?["backend"] as? String == "screen")
    }

    @Test func missingBackendFallsBackToTheDefaultAndSaysSo() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(screen: false))
        let outcome = await RsshdConnectFlow.run(.init(backend: .screen, attachTo: nil, cols: 80, rows: 24),
                                                 client: pipe.client())
        guard case .attach(let attachment) = outcome else { Issue.record("\(outcome)"); return }
        #expect(attachment.backend == "tmux")
        #expect(attachment.note == "screen is not available on this server; using tmux")
    }

    @Test func notInstalledIsAPlainShell() async {
        let pipe = FakeRsshdPipe()
        let client = pipe.client()
        async let outcome = RsshdConnectFlow.run(.init(backend: .tmux, attachTo: nil, cols: 80, rows: 24),
                                                client: client)
        pipe.close(throwing: RsshdExit(status: 127))
        #expect(await outcome == .plain(.notInstalled))
    }

    @Test func otherExitIsAPlainShellWithTheReason() async {
        let pipe = FakeRsshdPipe()
        let client = pipe.client()
        async let outcome = RsshdConnectFlow.run(.init(backend: .tmux, attachTo: nil, cols: 80, rows: 24),
                                                client: client)
        pipe.close(throwing: RsshdExit(status: 1))
        #expect(await outcome == .plain(.failed("rsshd rpc ended with exit status 1")))
    }

    @Test func createFailureIsAPlainShell() async {
        let pipe = FakeRsshdPipe(autoReply: daemon(createError: "tmux: no server"))
        let outcome = await RsshdConnectFlow.run(.init(backend: .tmux, attachTo: nil, cols: 80, rows: 24),
                                                 client: pipe.client())
        #expect(outcome == .plain(.failed("tmux: no server")))
    }
}

@Suite struct AttachOutputGateTests {
    @Test func dropsTheTypedCommandUntilTheAlternateScreen() {
        var gate = AttachOutputGate()
        #expect(gate.feed(Array("$  exec sh -c '…'\r\n".utf8)).isEmpty)
        #expect(!gate.isOpen)
        let passed = gate.feed(Array("x\u{1b}[?1049h\u{1b}[H screen".utf8))
        #expect(passed == Array("\u{1b}[?1049h\u{1b}[H screen".utf8))
        #expect(gate.isOpen)
        #expect(gate.feed([0x41]) == [0x41])
    }

    @Test func findsTheMarkerAcrossChunks() {
        var gate = AttachOutputGate()
        #expect(gate.feed(Array("prompt \u{1b}[?10".utf8)).isEmpty)
        #expect(gate.feed(Array("49hX".utf8)) == Array("\u{1b}[?1049hX".utf8))
    }

    @Test func openingByHandReleasesEverythingHeld() {
        var gate = AttachOutputGate()
        _ = gate.feed(Array("sh: rsshd: not found\r\n".utf8))
        #expect(gate.open() == Array("sh: rsshd: not found\r\n".utf8))
        #expect(gate.isOpen)
    }

    @Test func tooMuchOutputOpensTheGate() {
        var gate = AttachOutputGate(limit: 8)
        #expect(gate.feed(Array("0123456789".utf8)) == Array("0123456789".utf8))
        #expect(gate.isOpen)
    }
}
