import RSSHVNC
import Testing
@testable import RSSHRDP

@Suite struct RDPInputTests {
    @Test func specialKeysAreScancodes() {
        #expect(RDPInput.scancode(forKeysym: X11Keysym.returnKey) == .init(code: 0x1C, extended: false))
        #expect(RDPInput.scancode(forKeysym: X11Keysym.left) == .init(code: 0x4B, extended: true))
        #expect(RDPInput.scancode(forKeysym: X11Keysym.delete) == .init(code: 0x53, extended: true))
        #expect(RDPInput.scancode(forKeysym: X11Keysym.metaLeft) == .init(code: 0x5B, extended: true))
        #expect(RDPInput.scancode(forKeysym: X11Keysym.function(1)!) == .init(code: 0x3B, extended: false))
        #expect(RDPInput.scancode(forKeysym: X11Keysym.function(10)!) == .init(code: 0x44, extended: false))
        #expect(RDPInput.scancode(forKeysym: X11Keysym.function(12)!) == .init(code: 0x58, extended: false))
    }

    @Test func charactersAreNotScancodes() {
        #expect(RDPInput.scancode(forKeysym: 0x61) == nil)          // a
        #expect(RDPInput.scancode(forKeysym: 0x0100_20ac) == nil)   // €
    }

    @Test func pointerFlags() {
        #expect(RDPInput.flags(.left, down: true) == 0x9000)
        #expect(RDPInput.flags(.left, down: false) == 0x1000)
        #expect(RDPInput.flags(.right, down: true) == 0xA000)
        #expect(RDPInput.flags(.middle, down: false) == 0x4000)
        #expect(RDPInput.wheelFlags(up: true) == 0x0278)
        #expect(RDPInput.wheelFlags(up: false) == 0x0388)
    }
}

@Suite struct RDPSessionLifecycleTests {
    @Test func aSessionThatNeverConnectedFreesItselfAndIgnoresInput() {
        let session = RDPSession(port: 1, login: nil, pinnedCertificate: nil)
        session.pointer(x: 1, y: 1)
        session.type("x")
        session.disconnect()
        #expect(session.withFramebuffer { buffer, _, _, _ in buffer == nil })
    }

    @Test func aRefusedConnectionEndsWithAReason() async {
        let session = RDPSession(port: 1, login: nil, pinnedCertificate: nil)
        session.connect()
        var events: [RDPSessionEvent] = []
        for await event in session.events { events.append(event) }
        #expect(events.first == .connecting)
        guard case .disconnected(let reason)? = events.last else {
            Issue.record("expected disconnected, got \(events)")
            return
        }
        #expect(reason != nil)
        // After the end, input is dropped and the framebuffer is gone.
        session.pointer(x: 1, y: 1)
        #expect(session.withFramebuffer { buffer, _, _, _ in buffer == nil })
    }
}
