// One screen session for the pane, whatever the protocol: VNC (RoyalVNCKit) or RDP (libfreerdp3). Both report the
// same events; input arrives in framebuffer coordinates and X11 keysyms (GDK keyvals); frames become GdkTextures.
import CGtk
import Foundation
import RSSHKit
import RSSHRDP
import RSSHVNC

enum ScreenEvent: Sendable {
    case connecting
    case connected(width: Int, height: Int)
    case resized(width: Int, height: Int)
    case updated
    case remoteClipboard(String)
    case needsLogin
    case authenticationFailed(String)
    /// RDP: the certificate is not pinned (or not the pinned one); the session ended.
    case certificate(fingerprint: String, subject: String, verdict: RDPCertificatePolicy.Verdict)
    case disconnected(String?)
}

@MainActor
protocol RemoteScreen: AnyObject {
    var events: AsyncStream<ScreenEvent> { get }
    func connect()
    func disconnect()
    func pointer(x: Int, y: Int)
    /// `button`: 1 left, 2 middle, 3 right (GDK numbering).
    func button(_ button: UInt32, down: Bool, x: Int, y: Int)
    func scroll(up: Bool, steps: Int, x: Int, y: Int)
    func key(_ keysym: UInt32, down: Bool)
    func type(_ text: String)
    func sendClipboard(_ text: String)
    /// The current frame as a new GdkTexture (the caller unrefs it); nil before the first frame.
    func texture() -> gpointer?
}

private func mapped<E: Sendable>(_ source: AsyncStream<E>, _ map: @escaping @Sendable (E) -> ScreenEvent) -> AsyncStream<ScreenEvent> {
    AsyncStream { continuation in
        let task = Task {
            for await event in source { continuation.yield(map(event)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

@MainActor
final class VNCScreen: RemoteScreen {
    private let session: VNCSession
    let events: AsyncStream<ScreenEvent>

    init(port: Int, login: RemoteDesktopLogin?) {
        var options = VNCSession.Options()
        options.clipboard = false // no automatic pasteboard sync on Linux; the pane relays .remoteClipboard/sendClipboard
        session = VNCSession(port: port, login: login, options: options)
        events = mapped(session.events) { event in
            switch event {
            case .connecting: .connecting
            case .connected(let w, let h): .connected(width: w, height: h)
            case .resized(let w, let h): .resized(width: w, height: h)
            case .updated: .updated
            case .remoteClipboard(let text): .remoteClipboard(text)
            case .needsLogin: .needsLogin
            case .authenticationFailed(let reason): .authenticationFailed(reason)
            case .disconnected(let reason): .disconnected(reason)
            }
        }
    }

    func connect() { session.connect() }
    func disconnect() { session.disconnect() }
    func pointer(x: Int, y: Int) { session.pointer(x: x, y: y) }
    func button(_ button: UInt32, down: Bool, x: Int, y: Int) {
        session.button(button == 3 ? .right : button == 2 ? .middle : .left, down: down, x: x, y: y)
    }
    func scroll(up: Bool, steps: Int, x: Int, y: Int) { session.scroll(up ? .up : .down, steps: steps, x: x, y: y) }
    func key(_ keysym: UInt32, down: Bool) { session.key(keysym, down: down) }
    func type(_ text: String) { session.type(text) }
    func sendClipboard(_ text: String) { session.sendClipboard(text) }

    func texture() -> gpointer? {
        guard let fb = session.framebuffer else { return nil }
        let w = Int(fb.size.width), h = Int(fb.size.height)
        guard w > 0, h > 0 else { return nil }
        let count = min(fb.surfaceByteCount, w * h * 4)
        let bytes = g_bytes_new(fb.surfaceAddress, gsize(count))
        defer { g_bytes_unref(bytes) }
        return gdk_memory_texture_new(Int32(w), Int32(h), GDK_MEMORY_B8G8R8A8, bytes, gsize(w * 4)).gptr
    }
}

@MainActor
final class RDPScreen: RemoteScreen {
    private let session: RDPSession
    let events: AsyncStream<ScreenEvent>

    init(port: Int, login: RemoteDesktopLogin?, desktop: RemoteDesktop, width: Int, height: Int) {
        var options = RDPSession.Options()
        options.width = width
        options.height = height
        options.clipboard = desktop.shareClipboard
        session = RDPSession(port: port, login: login, domain: desktop.domain, pinnedCertificate: desktop.pinnedCertificate,
                             options: options)
        events = mapped(session.events) { event in
            switch event {
            case .connecting: .connecting
            case .connected(let w, let h): .connected(width: w, height: h)
            case .updated: .updated
            case .remoteClipboard(let text): .remoteClipboard(text)
            case .authenticationFailed(let reason): .authenticationFailed(reason)
            case .certificateNeedsTrust(let fp, let subject, let verdict): .certificate(fingerprint: fp, subject: subject, verdict: verdict)
            case .disconnected(let reason): .disconnected(reason)
            }
        }
    }

    func connect() { session.connect() }
    func disconnect() { session.disconnect() }
    func pointer(x: Int, y: Int) { session.pointer(x: x, y: y) }
    func button(_ button: UInt32, down: Bool, x: Int, y: Int) {
        session.button(button == 3 ? .right : button == 2 ? .middle : .left, down: down, x: x, y: y)
    }
    func scroll(up: Bool, steps: Int, x: Int, y: Int) { session.scroll(up: up, steps: steps, x: x, y: y) }
    func key(_ keysym: UInt32, down: Bool) { session.key(keysym, down: down) }
    func type(_ text: String) { session.type(text) }
    func sendClipboard(_ text: String) { session.setLocalClipboard(text) }

    func texture() -> gpointer? {
        session.withFramebuffer { buffer, w, h, stride -> gpointer? in
            guard let buffer, let base = buffer.baseAddress, w > 0, h > 0 else { return nil }
            let bytes = g_bytes_new(base, gsize(stride * h))
            defer { g_bytes_unref(bytes) }
            return gdk_memory_texture_new(Int32(w), Int32(h), GDK_MEMORY_B8G8R8X8, bytes, gsize(stride)).gptr
        }
    }
}
