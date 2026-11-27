import CRSSHRDP
import Foundation
import RSSHKit
import RSSHVNC
import Synchronization

/// What a session reports, in order, from its own thread. The same shape as `VNCSessionEvent`, so one screen view
/// serves both.
public enum RDPSessionEvent: Sendable, Equatable {
    case connecting
    /// The certificate is not the pinned one (or nothing is pinned yet): the session refused it and ends. Ask the
    /// user, pin `fingerprint` in the entry (`Vault.pinningRDPCertificate`) and connect again, as for SSH host keys.
    case certificateNeedsTrust(fingerprint: String, subject: String, verdict: RDPCertificatePolicy.Verdict)
    case connected(width: Int, height: Int)
    case updated(x: Int, y: Int, width: Int, height: Int)
    /// The server's clipboard text, when clipboard sharing is on.
    case remoteClipboard(String)
    case authenticationFailed(reason: String)
    case disconnected(reason: String?)
}

/// One RDP screen over libfreerdp3 (Linux), normally on the local end of an SSH tunnel. Software rendering into a
/// BGRX buffer (`withFramebuffer`); input is queued and sent from the session's thread.
public final class RDPSession: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        public var width = 1280
        public var height = 800
        /// Text clipboard both ways (cliprdr). Off unless the entry turns it on.
        public var clipboard = false
        /// The entry's Quality; nil leaves FreeRDP's defaults (32-bit colour).
        public var quality: RDPQualityProfile?
        public init() {}
    }

    public let events: AsyncStream<RDPSessionEvent>
    private let continuation: AsyncStream<RDPSessionEvent>.Continuation
    private let handle: OpaquePointer
    private let box: Box
    /// notStarted → running → finished. The run thread retains the session, so `deinit` only ever sees
    /// notStarted (free the handle here) or finished (the thread freed it).
    private enum Lifecycle { case notStarted, running, finished }
    private let lifecycle = Mutex(Lifecycle.notStarted)

    /// `pinnedCertificate`: the entry's pin; nil means the first certificate is only reported, never accepted.
    public init(host: String = "127.0.0.1", port: Int, login: RemoteDesktopLogin?, domain: String? = nil,
                pinnedCertificate: String?, options: Options = Options()) {
        let (stream, continuation) = AsyncStream.makeStream(of: RDPSessionEvent.self,
                                                            bufferingPolicy: .bufferingNewest(512))
        events = stream
        self.continuation = continuation
        box = Box(continuation: continuation, pinned: pinnedCertificate)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        var callbacks = rssh_rdp_callbacks()
        callbacks.ctx = ctx
        callbacks.certificate = { ctx, fingerprint, subject, issuer in
            Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                .certificate(String(cString: fingerprint!), subject: String(cString: subject!)) ? 1 : 0
        }
        callbacks.connected = { ctx, width, height in
            Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                .continuation.yield(.connected(width: Int(width), height: Int(height)))
        }
        callbacks.frame = { ctx, x, y, w, h in
            Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                .continuation.yield(.updated(x: Int(x), y: Int(y), width: Int(w), height: Int(h)))
        }
        callbacks.remote_text = { ctx, text in
            Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                .continuation.yield(.remoteClipboard(String(cString: text!)))
        }
        callbacks.cursor = { ctx, kind, rgba, width, height, hotX, hotY in
            let box = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
            let shape: RemoteCursor? = switch kind {
            case 0: rgba.flatMap { pixels in
                RemoteCursor(width: Int(width), height: Int(height), hotX: Int(hotX), hotY: Int(hotY),
                             rgba: Array(UnsafeBufferPointer(start: pixels, count: Int(width) * Int(height) * 4)))
            }
            case 1: RemoteCursor.hidden
            default: nil   // the system default: the app draws its arrow
            }
            box.setCursor(shape)
            // An empty update: the view redraws and picks up the new shape.
            box.continuation.yield(.updated(x: 0, y: 0, width: 0, height: 0))
        }
        let user = login?.username, pass = login?.password
        handle = host.withCString { h in
            Self.withOptionalCString(user) { u in
                Self.withOptionalCString(domain) { d in
                    Self.withOptionalCString(pass) { p in
                        var config = rssh_rdp_config()
                        config.host = h
                        config.port = UInt16(clamping: port)
                        config.username = u
                        config.domain = d
                        config.password = p
                        config.width = UInt32(options.width)
                        config.height = UInt32(options.height)
                        config.clipboard = options.clipboard ? 1 : 0
                        if let q = options.quality { Self.apply(q, to: &config) }
                        return rssh_rdp_new(&config, callbacks)
                    }
                }
            }
        }
    }

    deinit {
        if lifecycle.withLock({ $0 }) == .notStarted { rssh_rdp_free(handle) }
    }

    /// Starts the session on its own thread (once).
    public func connect() {
        let first = lifecycle.withLock { state -> Bool in
            guard state == .notStarted else { return false }
            state = .running
            return true
        }
        guard first else { return }
        continuation.yield(.connecting)
        let thread = Thread { [self] in
            let code = rssh_rdp_run(handle)
            if box.refusedCertificate {
                continuation.yield(.disconnected(reason: nil))
            } else if code == 0 {
                continuation.yield(.disconnected(reason: nil))
            } else {
                let reason = String(cString: rssh_rdp_error_string(code))
                if rssh_rdp_is_auth_error(code) != 0 { continuation.yield(.authenticationFailed(reason: reason)) }
                continuation.yield(.disconnected(reason: reason))
            }
            continuation.finish()
            lifecycle.withLock { state in
                rssh_rdp_free(handle)
                state = .finished
            }
        }
        thread.name = "rssh-rdp"
        thread.start()
    }

    /// Ends the session; safe at any time (the handle is only touched while it exists).
    public func disconnect() {
        lifecycle.withLock { state in if state == .running { rssh_rdp_stop(handle) } }
    }

    /// The framebuffer (BGRX, `stride` bytes per row) while `body` runs; nil before the first frame.
    public func withFramebuffer<T>(_ body: (UnsafeRawBufferPointer?, _ width: Int, _ height: Int, _ stride: Int) -> T) -> T {
        lifecycle.withLock { state in
            guard state != .finished else { return body(nil, 0, 0, 0) }
            var w: UInt32 = 0, h: UInt32 = 0, stride: UInt32 = 0
            let base = rssh_rdp_lock_buffer(handle, &w, &h, &stride)
            defer { rssh_rdp_unlock_buffer(handle) }
            let buffer = base.map { UnsafeRawBufferPointer(start: $0, count: Int(stride) * Int(h)) }
            return body(buffer, Int(w), Int(h), Int(stride))
        }
    }

    // MARK: input (framebuffer coordinates)

    /// Runs `body` with the handle while the session has not finished (input after the end is dropped).
    private func live(_ body: (OpaquePointer) -> Void) {
        lifecycle.withLock { state in if state != .finished { body(handle) } }
    }

    public func pointer(x: Int, y: Int) {
        live { h in rssh_rdp_mouse(h, RDPInput.move, UInt16(clamping: x), UInt16(clamping: y)) }
    }

    public func button(_ button: RDPInput.Button, down: Bool, x: Int, y: Int) {
        live { h in rssh_rdp_mouse(h, RDPInput.flags(button, down: down), UInt16(clamping: x), UInt16(clamping: y)) }
    }

    public func scroll(up: Bool, steps: Int, x: Int, y: Int) {
        for _ in 0..<min(max(steps, 0), 50) {
            live { h in rssh_rdp_mouse(h, RDPInput.wheelFlags(up: up), UInt16(clamping: x), UInt16(clamping: y)) }
        }
    }

    /// A key by X11 keysym: special keys as scancodes, characters as Unicode.
    public func key(_ keysym: UInt32, down: Bool) {
        if let code = RDPInput.scancode(forKeysym: keysym) {
            live { h in rssh_rdp_scancode(h, code.code, code.extended ? 1 : 0, down ? 1 : 0) }
        } else if let scalar = Unicode.Scalar(keysym >= 0x0100_0000 ? keysym - 0x0100_0000 : keysym) {
            live { h in for unit in String(Character(scalar)).utf16 { rssh_rdp_unicode(h, unit, down ? 1 : 0) } }
        }
    }

    /// Types text: Return and Tab as keys, the rest as Unicode characters.
    public func type(_ text: String) {
        for sym in X11Keysym.keysyms(typing: text) {
            key(sym, down: true)
            key(sym, down: false)
        }
    }

    // MARK: resize

    /// True once the server opened display control: `resize` then changes the running desktop's size.
    public var canResizeLive: Bool {
        lifecycle.withLock { state in state == .running && rssh_rdp_can_resize(handle) != 0 }
    }

    /// Asks the server for a desktop of `width` x `height` (even, 200...8192). It answers with a new
    /// `.connected` event at the size it chose. Nothing happens without display control (`canResizeLive`).
    public func resize(width: Int, height: Int) {
        live { h in rssh_rdp_resize(h, UInt32(clamping: max(0, width)), UInt32(clamping: max(0, height))) }
    }

    /// Offers this device's clipboard text to the server (clipboard sharing on).
    public func setLocalClipboard(_ text: String) {
        live { h in text.withCString { rssh_rdp_set_local_text(h, $0) } }
    }

    private static func apply(_ q: RDPQualityProfile, to config: inout rssh_rdp_config) {
        func flag(_ b: Bool) -> Int32 { b ? 1 : 0 }
        config.color_depth = q.colorDepth
        config.connection_type = q.connectionType
        config.network_autodetect = flag(q.networkAutoDetect)
        config.remote_fx = flag(q.remoteFX)
        config.wallpaper = flag(q.wallpaper)
        config.themes = flag(q.themes)
        config.menu_anims = flag(q.menuAnimations)
        config.full_window_drag = flag(q.fullWindowDrag)
        config.font_smoothing = flag(q.fontSmoothing)
        config.composition = flag(q.desktopComposition)
        config.compression = flag(q.compression)
    }

    // MARK: cursor, codec

    /// The pointer shape the server set: nil for none yet or the system default (draw an arrow), `.hidden` when it
    /// hid the pointer. A change is reported as an empty `.updated`.
    public var cursor: RemoteCursor? { box.cursor }

    /// What the last screen update used, for a stats line.
    public var codec: String {
        let code = lifecycle.withLock { state in state == .finished ? Int32(0) : rssh_rdp_codec(handle) }
        return switch code {
        case 1: "Bitmap"
        case 2: "RemoteFX"
        case 3: "NSCodec"
        case 4: "Surface bits"
        default: "—"
        }
    }

    private static func withOptionalCString<T>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let s else { return body(nil) }
        return s.withCString { body($0) }
    }

    // MARK: callbacks

    final class Box: @unchecked Sendable {
        let continuation: AsyncStream<RDPSessionEvent>.Continuation
        let pinned: String?
        private(set) var refusedCertificate = false
        private let cursorLock = NSLock()
        private var latestCursor: RemoteCursor?
        var cursor: RemoteCursor? { cursorLock.withLock { latestCursor } }
        func setCursor(_ cursor: RemoteCursor?) { cursorLock.withLock { latestCursor = cursor } }

        init(continuation: AsyncStream<RDPSessionEvent>.Continuation, pinned: String?) {
            self.continuation = continuation
            self.pinned = pinned
        }

        /// Accepts only the pinned certificate; anything else is reported and refused (the app asks, pins, retries).
        func certificate(_ fingerprint: String, subject: String) -> Bool {
            let verdict = RDPCertificatePolicy.evaluate(presented: fingerprint, pinned: pinned)
            guard verdict != .accept else { return true }
            refusedCertificate = true
            continuation.yield(.certificateNeedsTrust(fingerprint: RDPCertificatePolicy.normalized(fingerprint),
                                                      subject: subject, verdict: verdict))
            return false
        }
    }
}
