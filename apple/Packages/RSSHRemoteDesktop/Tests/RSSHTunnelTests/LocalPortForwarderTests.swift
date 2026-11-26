import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import RSSHTunnel

/// The forwarder with a plain-TCP opener (no SSH): what it does with the bytes and the connections it carries.
/// The same forwarder over a real OpenSSH server is in `SSHTunnelIntegrationTests`.
@Suite struct LocalPortForwarderTests {
    @Test func bytesGoBothWaysThroughTheListener() async throws {
        let echo = try await EchoServer.start()
        let opener = PlainTCPOpener()
        let forwarder = try await LocalPortForwarder.start(opener: opener, targetHost: "127.0.0.1",
                                                           targetPort: echo.port)
        #expect(forwarder.localPort > 0)
        #expect(forwarder.localPort != echo.port)

        let reply = try await TCPProbe.exchange(port: forwarder.localPort, send: "hello tunnel\n", expect: 13)
        #expect(reply == "hello tunnel\n")
        #expect(opener.requests == [.init(host: "127.0.0.1", port: echo.port)])

        await forwarder.close()
        await echo.close()
    }

    @Test func severalConnectionsAtOnceEachGetTheirOwnForward() async throws {
        let echo = try await EchoServer.start()
        let opener = PlainTCPOpener()
        let forwarder = try await LocalPortForwarder.start(opener: opener, targetHost: "127.0.0.1",
                                                           targetPort: echo.port)
        try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<5 {
                group.addTask { try await TCPProbe.exchange(port: forwarder.localPort, send: "n\(i)\n", expect: 3) }
            }
            var replies: Set<String> = []
            for try await reply in group { replies.insert(reply) }
            #expect(replies == Set((0..<5).map { "n\($0)\n" }))
        }
        #expect(opener.requests.count == 5)
        await forwarder.close()
        await echo.close()
    }

    @Test func aLargeTransferArrivesWhole() async throws {
        let echo = try await EchoServer.start()
        let forwarder = try await LocalPortForwarder.start(opener: PlainTCPOpener(), targetHost: "127.0.0.1",
                                                           targetPort: echo.port)
        let big = String(repeating: "0123456789abcdef", count: 64 * 1024)   // 1 MiB
        let reply = try await TCPProbe.exchange(port: forwarder.localPort, send: big, expect: big.utf8.count)
        #expect(reply == big)
        await forwarder.close()
        await echo.close()
    }

    @Test func aForwardTheServerRefusesClosesTheLocalConnectionAndIsReported() async throws {
        let forwarder = try await LocalPortForwarder.start(opener: FailingOpener(), targetHost: "10.0.0.1",
                                                           targetPort: 5900)
        let reply = try await TCPProbe.exchange(port: forwarder.localPort, send: "x", expect: 1)
        #expect(reply.isEmpty)   // closed without a byte
        let events = await forwarder.recentEvents()
        #expect(events.contains(.forwardFailed("administratively prohibited")))
        await forwarder.close()
    }

    @Test func closeStopsListeningAndDropsOpenConnections() async throws {
        let echo = try await EchoServer.start()
        let forwarder = try await LocalPortForwarder.start(opener: PlainTCPOpener(), targetHost: "127.0.0.1",
                                                           targetPort: echo.port)
        let port = forwarder.localPort
        let open = try await TCPProbe.connect(port: port)
        await forwarder.close()
        try await open.closeFuture.get()   // the forwarder closed it
        await #expect(throws: (any Error).self) { _ = try await TCPProbe.connect(port: port) }
        await echo.close()
    }

    @Test func anAcceptLimitStopsListeningOnceReached() async throws {
        let echo = try await EchoServer.start()
        let forwarder = try await LocalPortForwarder.start(opener: PlainTCPOpener(), targetHost: "127.0.0.1",
                                                           targetPort: echo.port, acceptLimit: 1)
        let reply = try await TCPProbe.exchange(port: forwarder.localPort, send: "one\n", expect: 4)
        #expect(reply == "one\n")
        // The listener closes on its event loop right after the limit is reached, not before the reply: wait for it.
        for _ in 0..<100 where forwarder.isListening { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!forwarder.isListening)
        await #expect(throws: (any Error).self) { _ = try await TCPProbe.connect(port: forwarder.localPort) }
        await forwarder.close()
        await echo.close()
    }

    @Test func anAcceptLimitBelowOneIsRefused() async throws {
        await #expect(throws: LocalPortForwarder.StartError.invalidAcceptLimit(0)) {
            _ = try await LocalPortForwarder.start(opener: PlainTCPOpener(), targetHost: "h", targetPort: 1,
                                                   acceptLimit: 0)
        }
    }

    @Test func listensOnLoopbackOnly() async throws {
        await #expect(throws: LocalPortForwarder.StartError.notLoopback("0.0.0.0")) {
            _ = try await LocalPortForwarder.start(opener: PlainTCPOpener(), targetHost: "h", targetPort: 1,
                                                   bindHost: "0.0.0.0")
        }
        // ::1 is accepted (a host without IPv6, like a default docker container, cannot bind it).
        if let v6 = try? await LocalPortForwarder.start(opener: PlainTCPOpener(), targetHost: "h", targetPort: 1,
                                                        bindHost: "::1") {
            #expect(v6.localPort > 0)
            await v6.close()
        }
    }

    @Test(arguments: [0, -1, 65536])
    func refusesATargetPortOutOfRange(port: Int) async throws {
        await #expect(throws: LocalPortForwarder.StartError.invalidTargetPort(port)) {
            _ = try await LocalPortForwarder.start(opener: PlainTCPOpener(), targetHost: "h", targetPort: port)
        }
    }

    @Test func aChosenLocalPortIsUsed() async throws {
        let echo = try await EchoServer.start()
        let free = try await TCPProbe.freePort()
        let forwarder = try await LocalPortForwarder.start(opener: PlainTCPOpener(), targetHost: "127.0.0.1",
                                                           targetPort: echo.port, bindPort: free)
        #expect(forwarder.localPort == free)
        await forwarder.close()
        await echo.close()
    }
}
