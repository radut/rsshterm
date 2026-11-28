// A remote desktop pane: the tunnel (through the entry's SSH server, or direct after a warning), the VNC session
// (RoyalVNCKit), the picture (Fit or 1:1), pointer and keyboard (grabbed while focused, Ctrl+Alt releases, a badge
// says so), and progress / error cards with Retry, Edit, Open Terminal. RDP arrives with RDPSession.
@preconcurrency import Citadel
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHRemote
import RSSHTermLinux
import RSSHTunnel
import RSSHVNC

@MainActor
final class ScreenPane {
    let id: PaneID
    let desktopID: UUID
    unowned var window: MainWindow
    private(set) var widget: Widget!
    private var picture: Widget!
    private var scroller: Widget!
    private var card: Widget!
    private var cardSpinner: Widget!
    private var cardTitle: Widget!
    private var cardMessage: Widget!
    private var cardButtons: Widget!
    private var headerTitle: Widget!
    private var badge: Widget!
    private var fitButton: Widget!
    private var pasteButton: Widget!

    private(set) var title: String
    private(set) var state = "idle"
    private(set) var lastFocused = Date()
    var onFocus: (() -> Void)?
    var onTitle: (() -> Void)?

    private var mode = ScreenGeometry.Mode.fit
    private var grabbed = false
    private var directConfirmed = false
    private var session: (any RemoteScreen)?
    /// The login of the attempt in progress, kept for the reconnect after a certificate is trusted.
    private var currentLogin: RemoteDesktopLogin?
    /// Server clipboard text just put on this computer's clipboard (so it is not sent back).
    private var lastRemoteClipboard: String?
    private var clipboardWatch: gulong = 0
    private var forwarder: LocalPortForwarder?
    private var connection: SSHConnection?
    private var eventsTask: Task<Void, Never>?
    private var pendingSave: Credential?
    private var pendingUser: String?
    private var authFailed = false
    private var remoteSize = (0, 0)
    private var redrawQueued = false
    private var pressed: Set<UInt32> = []
    /// Started before the vault was open (session restore): starts again when it opens.
    private(set) var waitingForVault = false

    init(id: PaneID, desktopID: UUID, window: MainWindow) {
        self.id = id
        self.desktopID = desktopID
        self.window = window
        title = "Screen"
        build()
        refreshHeader()
        start()
    }

    var desktop: RemoteDesktop? { window.app.vault?.remoteDesktops.first { $0.id == desktopID } }

    // MARK: Widgets

    private func build() {
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        g_object_ref_sink(widget.gptr)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        gtk_widget_add_css_class(widget, "screen-pane")

        let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        setMargins(header, 4)
        gtk_box_append(cast(header), gtk_image_new_from_icon_name("video-display-symbolic"))
        headerTitle = label("", css: ["heading"])
        gtk_label_set_ellipsize(cast(headerTitle), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(headerTitle, 1)
        gtk_label_set_xalign(cast(headerTitle), 0)
        gtk_box_append(cast(header), headerTitle)
        badge = label("⌨ Keys go to the screen · Ctrl+Alt releases", css: ["screen-grab-badge", "caption"])
        gtk_widget_set_visible(badge, 0)
        gtk_box_append(cast(header), badge)
        fitButton = button("Fit", css: ["flat"]) { [unowned self] in toggleScale() }
        gtk_widget_set_tooltip_text(fitButton, "Fit the window / show 1:1")
        gtk_box_append(cast(header), fitButton)
        pasteButton = iconButton("edit-paste-symbolic", tooltip: "Type the clipboard on the screen") { [unowned self] in pasteClipboard() }
        gtk_widget_add_css_class(pasteButton, "flat")
        gtk_box_append(cast(header), pasteButton)
        let more = iconButton("view-more-symbolic", tooltip: "More") { }
        gtk_widget_add_css_class(more, "flat")
        on(more, "clicked") { [unowned self] in moreMenu(more) }
        gtk_box_append(cast(header), more)
        gtk_box_append(cast(widget), header)
        // The header is the screen's title strip: drag it to move the pane (like a terminal's grab handle).
        let paneID = id
        installDrag(on: header, DragSourceSpec(item: { .pane(paneID) }, picture: { [weak self] in self?.widget },
                                               app: { [weak self] in self?.window.app }))

        let overlay = gtk_overlay_new()!
        gtk_widget_set_vexpand(overlay, 1)
        picture = gtk_picture_new()
        gtk_widget_set_focusable(picture, 1)
        gtk_widget_set_can_focus(picture, 1)
        gtk_widget_add_css_class(picture, "screen-picture")
        scroller = scrolled(picture)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_overlay_set_child(cast(overlay), scroller)

        card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)
        gtk_widget_set_halign(card, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(card, GTK_ALIGN_CENTER)
        gtk_widget_add_css_class(card, "card")
        setMargins(card, 24)
        cardSpinner = gtk_spinner_new()
        gtk_widget_set_size_request(cardSpinner, 32, 32)
        cardTitle = label("", css: ["title-3"])
        cardMessage = label("", css: ["dim-label"], wrap: true)
        gtk_label_set_xalign(cast(cardMessage), 0.5)
        gtk_label_set_justify(cast(cardMessage), GTK_JUSTIFY_CENTER)
        gtk_widget_set_size_request(cardMessage, 360, -1)
        cardButtons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_widget_set_halign(cardButtons, GTK_ALIGN_CENTER)
        for w in [cardSpinner!, cardTitle!, cardMessage!, cardButtons!] {
            setMargins(w, 6)
            gtk_box_append(cast(card), w)
        }
        gtk_overlay_add_overlay(cast(overlay), card)
        gtk_box_append(cast(widget), overlay)

        installInput()
    }

    func grabFocus() { gtk_widget_grab_focus(picture) }

    /// The pane holds keys only while its picture has focus.
    var isGrabbingKeys: Bool { grabbed && gtk_widget_has_focus(picture) != 0 }

    private func refreshHeader() {
        guard let d = desktop else {
            gtk_label_set_text(cast(headerTitle), "Remote desktop (deleted)")
            return
        }
        title = d.name
        gtk_label_set_text(cast(headerTitle), "\(d.name)  ·  \(SidebarRows.subtitle(d, servers: window.app.vault?.servers ?? []))")
        gtk_widget_set_visible(pasteButton, d.shareClipboard ? 1 : 0)
        onTitle?()
    }

    private func show(_ c: ScreenCard?) {
        guard let c else {
            gtk_widget_set_visible(card, 0)
            return
        }
        gtk_widget_set_visible(card, 1)
        gtk_label_set_text(cast(cardTitle), c.title)
        gtk_label_set_text(cast(cardMessage), c.message)
        gtk_widget_set_visible(cardMessage, c.message.isEmpty ? 0 : 1)
        gtk_widget_set_visible(cardSpinner, c.busy ? 1 : 0)
        c.busy ? gtk_spinner_start(cast(cardSpinner)) : gtk_spinner_stop(cast(cardSpinner))
        while let child = gtk_widget_get_first_child(cardButtons) { gtk_box_remove(cast(cardButtons), child) }
        for action in c.actions {
            let (title, css): (String, [String]) = switch action {
            case .retry: ("Retry", ["suggested-action", "pill"])
            case .edit: ("Edit…", ["pill"])
            case .openTerminal: ("Open Terminal", ["pill"])
            case .trustNew: ("Trust New…", ["destructive-action", "pill"])
            }
            gtk_box_append(cast(cardButtons), button(title, css: css) { [unowned self] in perform(action) })
        }
        state = c.busy ? "progress" : (c.actions.isEmpty ? "info" : "error: \(c.message)")
    }

    private func perform(_ action: ScreenCard.Action) {
        switch action {
        case .retry: start()
        case .edit: window.editRemoteDesktop(desktopID)
        case .openTerminal: if let server = desktop?.tunnelServerID { window.openSSH(server, split: false) }
        case .trustNew: trustNewCertificate()
        }
    }

    private func moreMenu(_ anchor: Widget) {
        var items: [(String, @MainActor () -> Void)] = [
            ("Send Ctrl+Alt+Del", { [unowned self] in sendChord([0xffe3, 0xffe9, 0xffff]) }),
            ("Reconnect", { [unowned self] in start() }),
            ("Disconnect", { [unowned self] in stop(); show(.disconnected(nil)) }),
            ("Edit…", { [unowned self] in window.editRemoteDesktop(desktopID) }),
        ]
        if let server = desktop?.tunnelServerID {
            items.append(("Open Terminal on the SSH Server", { [unowned self] in window.openSSH(server, split: false) }))
        }
        contextMenu(on: anchor, x: 8, y: 24, items: items)
    }

    // MARK: Connect

    /// Starts (or restarts) the flow: confirm direct → login sheet when needed → tunnel → screen.
    func start() {
        stop()
        refreshHeader()
        waitingForVault = window.app.vault == nil
        guard let vault = window.app.vault, let d = desktop else {
            return show(ScreenCard(title: "Locked", message: "Unlock the vault to open this screen.", actions: [.retry], busy: false))
        }
        switch RemoteDesktopConnectPlan.start(d, in: vault, directConfirmed: directConfirmed) {
        case .confirmDirect(let risk):
            show(.progress("Waiting for your answer…"))
            let body = risk == .notEncrypted
                ? "\(d.name) is reached without SSH: VNC is not encrypted, so the password challenge and every frame cross the network as they are."
                : "\(d.name) is reached without SSH: its RDP port must be open to this network."
            alert("Connect Directly?", body, responses: [Response(id: "cancel", label: "Cancel"),
                                                          Response(id: "go", label: "Connect", look: .destructive)],
                  parent: window.window) { [unowned self] id in
                guard id == "go" else { return show(.disconnected("Not connected.")) }
                directConfirmed = true
                start()
            }
        case .askLogin(let sheet):
            askLogin(sheet, desktop: d)
        case .connect(let login):
            connect(d, login: login)
        }
    }

    private func askLogin(_ sheet: RemoteDesktopLoginSheet, desktop d: RemoteDesktop) {
        show(.progress("Waiting for the login…"))
        RemoteDesktopLoginDialog(sheet: sheet, desktop: d, parent: window.window) { [unowned self] choice in
            guard let choice else { return show(.disconnected("Not connected.")) }
            guard let vault = window.app.vault else { return }
            let r = RemoteDesktopConnectPlan.resolve(choice, for: d, in: vault)
            pendingSave = r.saveOnSuccess
            if case .typed(let user, _, _) = choice { pendingUser = user }
            connect(d, login: r.login)
        }.present()
    }

    private func connect(_ d: RemoteDesktop, login: RemoteDesktopLogin?) {
        guard let vault = window.app.vault else { return }
        authFailed = false
        let route: RemoteDesktopRoute
        do { route = try vault.route(for: d) } catch {
            return show(.failed(error.localizedDescription, tunnelServer: nil))
        }
        let serverName = route.sshServer?.name
        show(.progress(serverName.map { "Connecting to \($0)…" } ?? "Connecting to \(d.host)…"))
        state = "connecting"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let opener: any DirectTCPIPOpener
                if let server = route.sshServer {
                    // Linux terminals run OpenSSH, so there is no Citadel session to share: shared and separate
                    // both open a connection of their own (the server's login, jump hosts and pinned host keys).
                    let sshRoute = try SSHRoute.resolve(server, in: vault, agentKeys: true)
                    let conn = try await SSHConnector().connect(sshRoute)
                    connection = conn
                    opener = CitadelForwardOpener(client: conn.target)
                } else {
                    opener = DirectTCPOpener()
                }
                show(.progress("Opening screen…"))
                let fwd = try await LocalPortForwarder.start(opener: opener, targetHost: route.target.host,
                                                             targetPort: route.target.port,
                                                             acceptLimit: d.kind == .appleScreenSharing ? 2 : 1)
                forwarder = fwd
                if d.kind == .appleScreenSharing {
                    let hello = try await RFBProbe.hello(host: "127.0.0.1", port: fwd.localPort)
                    switch VNCAuthPlan.plan(for: hello, preferAccount: true) {
                    case .inApp: break
                    case .screenSharingAppOnly: return show(.appleOnly)
                    case .refused(let reason): return show(.failed(reason, tunnelServer: nil))
                    case .unsupported: return show(.failed("This Mac offers no login type rSshTerm speaks.", tunnelServer: nil))
                    }
                }
                startSession(port: fwd.localPort, login: login, desktop: d)
            } catch let error as RemoteConnectError {
                if case .unknownHostKey = error {
                    show(ScreenCard(title: "Trust \(serverName ?? "the server") first",
                                    message: "Its host key is not pinned yet: open a terminal to it once, check the key, then Retry.",
                                    actions: [.openTerminal, .retry], busy: false))
                } else {
                    show(.failed(error.errorDescription ?? "\(error)", tunnelServer: serverName))
                }
            } catch {
                show(.failed((error as? LocalizedError)?.errorDescription ?? "\(error)", tunnelServer: serverName))
            }
        }
    }

    private func startSession(port: Int, login: RemoteDesktopLogin?, desktop d: RemoteDesktop) {
        show(.progress(login == nil ? "Opening screen…" : "Logging in…"))
        currentLogin = login
        let s: any RemoteScreen
        if d.kind == .rdp {
            let (w, h) = RDPDesktopSize.requested(viewWidth: Int(gtk_widget_get_width(scroller)),
                                                  viewHeight: Int(gtk_widget_get_height(scroller)))
            s = RDPScreen(port: port, login: login, desktop: d, width: w, height: h)
        } else {
            s = VNCScreen(port: port, login: login)
        }
        session = s
        eventsTask = Task { @MainActor [weak self] in
            for await event in s.events {
                guard let self else { return }
                handle(event, desktop: d)
            }
        }
        s.connect()
    }

    private func handle(_ event: ScreenEvent, desktop d: RemoteDesktop) {
        switch event {
        case .connecting:
            state = "connecting"
        case .connected(let w, let h):
            remoteSize = (w, h)
            state = "connected \(w)x\(h)"
            show(nil)
            // Keys go to the screen only when the user is on this pane now (they just opened it); otherwise a
            // click on the picture grabs them. A server-side event never moves focus.
            if window.isFocusedPane(id) {
                grabbed = true
                grabFocus()
            }
            updateBadge()
            redraw()
            if let credential = pendingSave { saveLogin(credential, desktop: d) }
            watchLocalClipboard(d)
        case .resized(let w, let h):
            remoteSize = (w, h)
            state = "connected \(w)x\(h)"
            redraw()
        case .updated:
            redraw()
        case .remoteClipboard(let text):
            // Only with the entry's clipboard opt-in: the screen's copied text becomes this computer's.
            guard d.shareClipboard, !text.isEmpty else { return }
            lastRemoteClipboard = text
            copyToClipboard(text, from: picture)
        case .certificate(let fingerprint, let subject, let verdict):
            authFailed = true // the session ends; the card or the question below replaces "Disconnected"
            stop()
            askCertificate(fingerprint: fingerprint, subject: subject, verdict: verdict, desktop: d)
        case .needsLogin:
            authFailed = true
            stop()
            if let vault = window.app.vault { askLogin(RemoteDesktopConnectPlan.loginSheet(d, in: vault, error: nil), desktop: d) }
        case .authenticationFailed(let reason):
            authFailed = true
            pendingSave = nil
            stop()
            if let vault = window.app.vault, case .askLogin(let sheet) = RemoteDesktopConnectPlan.afterAuthFailure(d, in: vault, reason: reason) {
                askLogin(sheet, desktop: d)
            }
        case .disconnected(let reason):
            guard !authFailed else { return }
            state = "disconnected"
            grabbed = false
            updateBadge()
            show(.disconnected(reason))
            Task { await self.closeTransport() }
        }
    }

    /// RDP certificate trust on first use; a changed certificate is refused with a card, and only "Trust New…" plus
    /// a destructive confirmation pins it.
    private func askCertificate(fingerprint: String, subject: String, verdict: RDPCertificatePolicy.Verdict, desktop d: RemoteDesktop) {
        switch verdict {
        case .askToTrust:
            show(.progress("Waiting for your answer…"))
            state = "certificate-question"
            alert("Trust This Screen's Certificate?",
                  "\(d.name) presents a certificate for “\(subject)” with the SHA-256 fingerprint\n\(fingerprint)\n"
                    + "Check it with its administrator if you can. Trusted, it is pinned in the vault entry and checked on every connect.",
                  responses: [Response(id: "cancel", label: "Cancel"), Response(id: "trust", label: "Trust and Connect", look: .suggested)],
                  defaultID: "trust", parent: window.window) { [unowned self] id in
                guard id == "trust" else { return show(.disconnected("Not connected: the certificate was not trusted.")) }
                pin(fingerprint, desktop: d)
            }
        case .changed(let expected):
            pendingFingerprint = fingerprint
            show(.certificateChanged(expected: expected, presented: fingerprint))
        case .accept, .refuse:
            show(.failed("The certificate was refused.", tunnelServer: nil))
        }
    }

    private var pendingFingerprint: String?

    private func trustNewCertificate() {
        guard let fingerprint = pendingFingerprint, let d = desktop else { return }
        alert("Trust the New Certificate?",
              "Only if you know why it changed (the server was reinstalled or got a new certificate). Otherwise someone may be "
                + "reading this connection.\nNew fingerprint: \(fingerprint)",
              responses: [Response(id: "cancel", label: "Cancel"), Response(id: "trust", label: "Trust New Certificate", look: .destructive)],
              parent: window.window) { [unowned self] id in
            guard id == "trust" else { return }
            pin(fingerprint, desktop: d)
        }
    }

    /// Pins `fingerprint` in the entry and connects again with the same login.
    private func pin(_ fingerprint: String, desktop d: RemoteDesktop) {
        guard let document = window.app.document else { return }
        let login = currentLogin
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await document.commit(try document.vault.pinningRDPCertificate(fingerprint, for: d.id))
            } catch {
                return show(.failed("The certificate could not be saved: \(error.localizedDescription)", tunnelServer: nil))
            }
            pendingFingerprint = nil
            guard let fresh = desktop else { return }
            connect(fresh, login: login)
        }
    }

    /// With the entry's clipboard opt-in: text copied on this computer goes to the screen.
    private func watchLocalClipboard(_ d: RemoteDesktop) {
        guard d.shareClipboard, clipboardWatch == 0 else { return }
        let clipboard = gtk_widget_get_clipboard(picture)
        clipboardWatch = on(clipboard, "changed") { [weak self] in
            guard let self, let s = session else { return }
            window.app.readClipboard(from: picture) { [weak self] text in
                guard let self, let text, !text.isEmpty, text != lastRemoteClipboard else { return }
                s.sendClipboard(text)
            }
        }
    }

    private func saveLogin(_ credential: Credential, desktop d: RemoteDesktop) {
        pendingSave = nil
        guard let document = window.app.document else { return }
        let user = pendingUser
        Task { @MainActor in
            guard let next = try? document.vault.savingRemoteDesktopLogin(credential, username: user, for: d.id) else { return }
            try? await document.commit(next)
        }
    }

    /// Ends the session and the tunnel (Disconnect, close, before a retry).
    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        session?.disconnect()
        session = nil
        if clipboardWatch != 0, picture != nil {
            g_signal_handler_disconnect(gtk_widget_get_clipboard(picture).gptr, clipboardWatch)
            clipboardWatch = 0
        }
        grabbed = false
        if badge != nil { updateBadge() }
        Task { await self.closeTransport() }
    }

    private func closeTransport() async {
        if let f = forwarder { forwarder = nil; await f.close() }
        if let c = connection { connection = nil; await c.close() }
    }

    // MARK: Picture

    private func redraw() {
        guard !redrawQueued else { return }
        redrawQueued = true
        onMain { [weak self] in
            guard let self else { return }
            redrawQueued = false
            guard let texture = session?.texture() else { return }
            gtk_picture_set_paintable(cast(picture), cast(texture))
            g_object_unref(texture)
        }
    }

    private func toggleScale() {
        mode = mode == .fit ? .actualSize : .fit
        gtk_button_set_label(cast(fitButton), mode == .fit ? "Fit" : "1:1")
        gtk_picture_set_can_shrink(cast(picture), mode == .fit ? 1 : 0)
        gtk_picture_set_content_fit(cast(picture), mode == .fit ? GTK_CONTENT_FIT_SCALE_DOWN : GTK_CONTENT_FIT_FILL)
        gtk_widget_set_halign(picture, mode == .fit ? GTK_ALIGN_FILL : GTK_ALIGN_START)
        gtk_widget_set_valign(picture, mode == .fit ? GTK_ALIGN_FILL : GTK_ALIGN_START)
    }

    private func remotePoint(_ x: Double, _ y: Double) -> (Int, Int)? {
        let g = ScreenGeometry(remoteWidth: remoteSize.0, remoteHeight: remoteSize.1,
                               viewWidth: Int(gtk_widget_get_width(picture)), viewHeight: Int(gtk_widget_get_height(picture)),
                               mode: mode)
        return g.toRemote(x: x, y: y)
    }

    private func updateBadge() {
        gtk_widget_set_visible(badge, isGrabbingKeys ? 1 : 0)
    }

    var focusText: String { state }

    // MARK: Input

    private func installInput() {
        let motion = gtk_event_controller_motion_new()
        onMotion(motion) { [unowned self] x, y in
            guard let s = session, let (rx, ry) = remotePoint(x, y) else { return }
            s.pointer(x: rx, y: ry)
        }
        gtk_widget_add_controller(picture, motion)

        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(click), 0)
        onPressed(click) { [unowned self] _, x, y in
            grabbed = true
            grabFocus()
            updateBadge()
            guard let s = session, let (rx, ry) = remotePoint(x, y) else { return }
            let n = gtk_gesture_single_get_current_button(cast(click))
            s.button(n, down: true, x: rx, y: ry)
        }
        onReleased(click) { [unowned self] _, x, y in
            guard let s = session, let (rx, ry) = remotePoint(x, y) else { return }
            let n = gtk_gesture_single_get_current_button(cast(click))
            s.button(n, down: false, x: rx, y: ry)
        }
        gtk_widget_add_controller(picture, cast(click))

        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        var lastPoint = (0.0, 0.0)
        onMotion(motion) { x, y in lastPoint = (x, y) }
        onScroll(scroll) { [unowned self] _, dy in
            guard let s = session, let (rx, ry) = remotePoint(lastPoint.0, lastPoint.1) else { return false }
            s.scroll(up: dy < 0, steps: max(1, Int(abs(dy).rounded())), x: rx, y: ry)
            return true
        }
        gtk_widget_add_controller(picture, cast(scroll))

        let keys = gtk_event_controller_key_new()!
        onKeyPressed(keys) { [unowned self] keyval, state in
            guard let s = session, grabbed else { return false }
            if KeyGrab.isReleaseChord(keyval: keyval, state: state) {
                releaseKeys()
                return true
            }
            pressed.insert(keyval)
            s.key(KeyGrab.keysym(for: keyval), down: true)
            return true
        }
        onKeyReleased(keys) { [unowned self] keyval, _ in
            guard let s = session, pressed.remove(keyval) != nil else { return }
            s.key(KeyGrab.keysym(for: keyval), down: false)
        }
        gtk_widget_add_controller(picture, keys)

        onFocusEnter(picture) { [unowned self] in
            lastFocused = Date()
            onFocus?()
            updateBadge()
        }
        let focus = gtk_event_controller_focus_new()!
        on(focus, "leave") { [unowned self] in
            // Keys held when focus left are released on the remote side too.
            for k in pressed { session?.key(k, down: false) }
            pressed.removeAll()
            updateBadge()
        }
        gtk_widget_add_controller(picture, focus)
    }

    /// Ctrl+Alt: the keys go back to rSshTerm until the screen is clicked again.
    private func releaseKeys() {
        for k in pressed { session?.key(k, down: false) }
        pressed.removeAll()
        grabbed = false
        updateBadge()
        window.toast("Keyboard released: click the screen to send keys to it again.")
    }

    private func sendChord(_ keysyms: [UInt32]) {
        guard let s = session else { return }
        for k in keysyms { s.key(k, down: true) }
        for k in keysyms.reversed() { s.key(k, down: false) }
    }

    private func pasteClipboard() {
        guard let s = session, desktop?.shareClipboard == true else { return }
        window.app.readClipboard(from: picture) { text in
            if let text, !text.isEmpty { s.type(text) }
        }
    }

    deinit {
        // `stop()` ran when the pane left the layout; the widget reference goes with the pane.
        g_object_unref(widget.gptr)
    }
}
