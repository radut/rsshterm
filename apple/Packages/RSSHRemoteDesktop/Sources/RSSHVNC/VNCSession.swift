import Foundation
import RoyalVNCKit
import RSSHKit

/// The login a screen is opened with (RSSHKit's, shared with the connect flow and RDP).
public typealias VNCLogin = RemoteDesktopLogin

/// What a session reports to its view, in order, from RoyalVNCKit's own queue.
public enum VNCSessionEvent: Sendable, Equatable {
    case connecting
    case connected(width: Int, height: Int)
    case resized(width: Int, height: Int)
    /// A changed rectangle of the framebuffer; the view redraws it from `VNCSession.framebuffer`.
    case updated(x: Int, y: Int, width: Int, height: Int)
    /// RoyalVNCKit asked for a login this session does not have (none stored, or a Mac account without a user).
    case needsLogin(accountType: VNCAccountKind)
    /// The server's clipboard text (every ServerCutText, synced or not); the app keeps the last for Get Clipboard.
    case remoteClipboard(String)
    /// The server refused the login (wrong password or user); `.disconnected` follows.
    case authenticationFailed(reason: String)
    /// Nil reason: closed on purpose (disconnect) or by the server without an error worth showing.
    case disconnected(reason: String?)
}

/// Which login RoyalVNCKit asked for, without RoyalVNCKit's type in the app's model.
public enum VNCAccountKind: Sendable, Equatable {
    case vncPassword
    case macAccount
    case windowsAccount
}

/// One screen over RoyalVNCKit (VNC password, Apple Remote Desktop, UltraVNC MS-Logon II), headless: a view
/// draws `framebuffer` on `.updated` events and sends input here.
///
/// Clipboard: off by default (the remote side would see whatever this device copies). When on, RoyalVNCKit polls
/// the system pasteboard (NSPasteboard/UIPasteboard) every 0.5 s and sends changes, and puts the server's cut text
/// there. On iOS keep it off: every poll of UIPasteboard shows the "pasted from" notice; the app pastes on
/// request with `type(_:)` instead. Not available on Linux (no pasteboard in RoyalVNCKit there).
public final class VNCSession: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        public var shared = true
        public var clipboard = false
        public var colorDepth = 24
        /// Frame encodings in the order the server should prefer them.
        public var encodings: [VNCFrameEncodingType] = VNCFrameEncodingType.defaultFrameEncodings
        public init() {}

        /// The entry's Quality: High prefers lossless ZRLE, Low bandwidth 16-bit colour with Tight first (RoyalVNCKit
        /// sets Tight's compression and JPEG levels itself), Auto and Balanced keep the defaults.
        public init(quality: RemoteDesktop.Quality) {
            self.init()
            switch quality {
            case .auto, .balanced:
                break
            case .high:
                encodings = [.zrle, .hextile, .zlib, .tight, .coRRE, .rre]
            case .lowBandwidth:
                colorDepth = 16
                encodings = [.tight, .zrle, .zlib, .hextile, .coRRE, .rre]
            }
        }
    }

    public let events: AsyncStream<VNCSessionEvent>
    private let continuation: AsyncStream<VNCSessionEvent>.Continuation
    private let connection: VNCConnection
    private let bridge: Bridge

    /// Opens `host:port`, normally the local end of an SSH tunnel (`LocalPortForwarder.localPort`).
    public init(host: String = "127.0.0.1", port: Int, login: VNCLogin?, options: Options = Options()) {
        let (stream, continuation) = AsyncStream.makeStream(of: VNCSessionEvent.self, bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.continuation = continuation
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,   // RoyalVNCKit's debug log is never on: it could show protocol bytes
            hostname: host, port: UInt16(clamping: port), isShared: options.shared, isScalingEnabled: true,
            useDisplayLink: false, inputMode: .none, isClipboardRedirectionEnabled: options.clipboard,
            colorDepth: options.colorDepth == 16 ? .depth16Bit : (options.colorDepth == 8 ? .depth8Bit : .depth24Bit),
            frameEncodings: options.encodings)
        connection = VNCConnection(settings: settings, logger: SilentLogger())
        bridge = Bridge(login: login, continuation: continuation)
        connection.delegate = bridge
        connection.serverCutTextHandler = { [continuation] text in continuation.yield(.remoteClipboard(text)) }
    }

    deinit { continuation.finish() }

    public func connect() { connection.connect() }
    public func disconnect() { connection.disconnect() }

    /// The pointer shape the server sent (Cursor pseudo-encoding); nil until it sends one. A change is reported as
    /// an empty `.updated`.
    public var cursor: RemoteCursor? { bridge.cursor }

    /// The pixels (BGRA, 32 bits per pixel) the view draws; nil before the server sent its size.
    public var framebuffer: VNCFramebuffer? { connection.framebuffer }

    // MARK: input (framebuffer coordinates)

    public func pointer(x: Int, y: Int) { connection.mouseMove(x: Self.c(x), y: Self.c(y)) }

    public func button(_ button: VNCMouseButton, down: Bool, x: Int, y: Int) {
        if down { connection.mouseButtonDown(button, x: Self.c(x), y: Self.c(y)) }
        else { connection.mouseButtonUp(button, x: Self.c(x), y: Self.c(y)) }
    }

    /// Scroll by whole wheel steps (a two-finger pan is turned into steps by the view).
    public func scroll(_ wheel: VNCMouseWheel, steps: Int, x: Int, y: Int) {
        guard steps > 0 else { return }
        connection.mouseWheel(wheel, x: Self.c(x), y: Self.c(y), steps: UInt32(min(steps, 50)))
    }

    public func key(_ keysym: UInt32, down: Bool) {
        if down { connection.keyDown(VNCKeyCode(keysym)) } else { connection.keyUp(VNCKeyCode(keysym)) }
    }

    /// Sends `text` as this device's clipboard (Send Clipboard); the system pasteboard is never read here.
    public func sendClipboard(_ text: String) {
        connection.sendClipboardText(text)
    }

    /// Types text as key presses (the on-screen keyboard, paste as typing).
    public func type(_ text: String) {
        for keysym in X11Keysym.keysyms(typing: text) {
            key(keysym, down: true)
            key(keysym, down: false)
        }
    }

    private static func c(_ v: Int) -> UInt16 { UInt16(clamping: v) }

    // MARK: RoyalVNCKit delegate

    final class Bridge: VNCConnectionDelegate, @unchecked Sendable {
        private let login: VNCLogin?
        private let continuation: AsyncStream<VNCSessionEvent>.Continuation

        init(login: VNCLogin?, continuation: AsyncStream<VNCSessionEvent>.Continuation) {
            self.login = login
            self.continuation = continuation
        }

        func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
            switch connectionState.status {
            case .connecting: continuation.yield(.connecting)
            case .connected, .disconnecting: break   // .connected is reported with the framebuffer size
            case .disconnected:
                let error = connectionState.error
                if let vnc = error as? VNCError, vnc.isAuthenticationError {
                    continuation.yield(.authenticationFailed(reason: Self.describe(vnc)))
                }
                let shown = (error as? VNCError).map(\.shouldDisplayToUser) ?? (error != nil)
                continuation.yield(.disconnected(reason: shown ? error.map(Self.describe) : nil))
            }
        }

        func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType,
                        completion: @escaping (VNCCredential?) -> Void) {
            let kind = Self.accountKind(authenticationType)
            guard let credential = VNCCredentials.credential(for: kind, login: login) else {
                continuation.yield(.needsLogin(accountType: kind))
                return completion(nil)
            }
            completion(credential)
        }

        func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
            continuation.yield(.connected(width: Int(framebuffer.size.width), height: Int(framebuffer.size.height)))
        }

        func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
            continuation.yield(.resized(width: Int(framebuffer.size.width), height: Int(framebuffer.size.height)))
        }

        func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                        x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
            continuation.yield(.updated(x: Int(x), y: Int(y), width: Int(width), height: Int(height)))
        }

        private let cursorLock = NSLock()
        private var latestCursor: RemoteCursor?
        var cursor: RemoteCursor? { cursorLock.withLock { latestCursor } }

        /// RoyalVNCKit decodes the cursor to RGBA with a 0/255 alpha from its mask.
        func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
            let shape = cursor.isEmpty ? RemoteCursor.hidden
                : RemoteCursor(width: Int(cursor.size.width), height: Int(cursor.size.height),
                               hotX: Int(cursor.hotspot.x), hotY: Int(cursor.hotspot.y), rgba: [UInt8](cursor.imageData))
            cursorLock.withLock { latestCursor = shape }
            continuation.yield(.updated(x: 0, y: 0, width: 0, height: 0))
        }

        static func accountKind(_ type: VNCAuthenticationType) -> VNCAccountKind {
            switch type {
            case .vnc: .vncPassword
            case .appleRemoteDesktop: .macAccount
            case .ultraVNCMSLogonII: .windowsAccount
            @unknown default: .vncPassword
            }
        }

        /// RoyalVNCKit's own text for user-facing errors; never the credential.
        static func describe(_ error: any Error) -> String {
            if let vnc = error as? VNCError { return vnc.localizedDescription }
            return String(describing: error)
        }
    }

    final class SilentLogger: VNCLogger {
        var isDebugLoggingEnabled = false
        func logDebug(_ message: @autoclosure () -> String) {}
        func logInfo(_ message: String) {}
        func logWarning(_ message: String) {}
        func logError(_ message: String) {}
    }
}

/// The RoyalVNCKit credential for what it asked; nil when the login cannot answer it.
public enum VNCCredentials {
    public static func credential(for kind: VNCAccountKind, login: VNCLogin?) -> (any VNCCredential)? {
        guard let login, !login.password.isEmpty else { return nil }
        switch kind {
        case .vncPassword:
            return VNCPasswordCredential(password: login.password)
        case .macAccount, .windowsAccount:
            guard let user = login.username, !user.isEmpty else { return nil }
            return VNCUsernamePasswordCredential(username: user, password: login.password)
        }
    }
}

extension RemoteDesktop {
    /// The login for this entry from the vault: its user and its password credential; nil when it has none.
    public func vncLogin(in vault: Vault) -> VNCLogin? {
        guard let id = credentialID, let credential = vault.credentials.first(where: { $0.id == id }),
              case .password(let password) = credential.kind else { return nil }
        return VNCLogin(username: kind.usesUsername ? username : nil, password: password)
    }
}

/// A plain value enum (RoyalVNCKit predates strict concurrency): safe to share.
extension VNCFrameEncodingType: @retroactive @unchecked Sendable {}
