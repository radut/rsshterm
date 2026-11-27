// One terminal pane: a VteTerminal running a SpawnPlan on VTE's own PTY.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

@MainActor
final class TerminalPane {
    let id: PaneID
    /// The VteTerminal, referenced by us for the pane's whole life (it moves between GtkPaned parents).
    let widget: Widget
    private(set) var title: String
    private(set) var pid: Int32 = -1
    private(set) var exited = false
    /// The SSH host for an SSH pane (jump switcher), nil for a local shell.
    let host: String?
    /// When the pane last had focus (most recent first in the jump switcher).
    private(set) var lastFocused = Date()
    var onExit: ((Int32) -> Void)?
    /// An ssh pane whose server refused the login (ssh exited 255 with "Permission denied"): the window offers
    /// "Try another login…".
    var onRefusedLogin: (() -> Void)?
    /// The bar over the bottom of the pane: "Try another login…" or "Save …?".
    private var bar: Widget?
    var onTitle: (() -> Void)?
    var onFocus: (() -> Void)?
    /// What the user typed into this pane (for broadcast input).
    var onCommit: ((String) -> Void)?

    var terminal: UnsafeMutablePointer<VteTerminal> { cast(widget) }
    /// What goes into the split tree: a GtkOverlay with the terminal and the broadcast badge.
    let container: Widget
    private let badge: Widget
    /// The broadcast stripes over the whole terminal: a drawing area (an overlay child that never takes clicks)
    /// filling the pane, clipped to it, its bands anchored to the window so they run on across dividers.
    private let hatch: Widget
    /// The terminal background is dark (the hatch uses the stronger opacity).
    private var darkBackground = true
    /// Right click on the terminal (x, y in the terminal).
    var onContextMenu: ((Double, Double) -> Void)?
    /// Clicking the badge takes this pane out of the broadcast (on the pane typed in: stops broadcasting).
    var onBadgeClicked: (() -> Void)?
    /// A drag of the pane's grab handle started (the window shows the drop zones) or ended.
    var onGrab: (() -> Void)?
    var onGrabEnded: (() -> Void)?
    /// While true, `commit` does not broadcast (input this pane got from a broadcast or a broadcast paste).
    var suppressBroadcast = false

    /// `plan` nil: the pane waits (an SSH pane restored before the vault is open); `start` spawns it later.
    /// The vault server of an SSH pane: its own font and theme win over Preferences.
    var server: Server?

    init(id: PaneID, plan: Result<SpawnPlan, SpawnError>?, host: String?, settings: AppSettings, dark: Bool, server: Server? = nil) {
        self.id = id
        self.host = host
        self.server = server
        widget = vte_terminal_new()
        g_object_ref_sink(widget.gptr)
        container = gtk_overlay_new()
        g_object_ref_sink(container.gptr)
        badge = gtk_button_new_from_icon_name(ConnectIcons.broadcastIconName)
        hatch = gtk_drawing_area_new()
        switch plan {
        case .success(let p)?: title = p.title
        case .failure?: title = "Error"
        case nil: title = host ?? "Waiting"
        }
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        gtk_overlay_set_child(cast(container), widget)
        gtk_widget_set_can_target(hatch, 0)
        gtk_widget_set_can_focus(hatch, 0)
        gtk_widget_set_hexpand(hatch, 1)
        gtk_widget_set_vexpand(hatch, 1)
        gtk_widget_set_overflow(hatch, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_visible(hatch, 0)
        gtk_overlay_add_overlay(cast(container), hatch)
        gtk_widget_set_halign(badge, GTK_ALIGN_END)
        gtk_widget_set_valign(badge, GTK_ALIGN_START)
        gtk_widget_set_margin_top(badge, 6)
        gtk_widget_set_margin_end(badge, 6)
        gtk_widget_set_tooltip_text(badge, Self.badgeTip(source: false))
        for c in ["broadcast-badge", "osd"] { gtk_widget_add_css_class(badge, c) }
        gtk_widget_set_visible(badge, 0)
        gtk_overlay_add_overlay(cast(container), badge)
        // The grab handle (top centre, clear of the prompt): drag it onto another pane's edge, a tab, or the tab strip to move the pane.
        let grip = gtk_image_new_from_icon_name("list-drag-handle-symbolic")!
        gtk_widget_set_halign(grip, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(grip, GTK_ALIGN_START)
        gtk_widget_set_margin_top(grip, 2)
        gtk_widget_set_tooltip_text(grip, "Drag to move this pane: onto another pane's edge, a tab, or the tab strip")
        gtk_widget_add_css_class(grip, "pane-grip")
        gtk_widget_set_cursor_from_name(grip, "grab")
        let drag = gtk_drag_source_new()!
        gtk_drag_source_set_actions(drag, GDK_ACTION_MOVE)
        let paneID = id
        onDragPrepare(drag) { [weak self] _, _ in
            self?.onGrab?()
            return textContent(DragPayload.pane(paneID).text)
        }
        onDragEnd(drag) { [weak self] in self?.onGrabEnded?() }
        onDragCancel(drag) { [weak self] _ in
            self?.onGrabEnded?()
            return false
        }
        gtk_widget_add_controller(grip, cast(drag))
        gtk_overlay_add_overlay(cast(container), grip)
        vte_terminal_set_mouse_autohide(terminal, 1)
        vte_terminal_set_bold_is_bright(terminal, 1)
        apply(settings, dark: dark)
        setDrawFunc(hatch) { [weak self] cr, w, h in self?.drawHatch(cr, width: Double(w), height: Double(h)) }

        onInt(widget, "child-exited") { [weak self] status in
            guard let self else { return }
            exited = true
            // A clean exit closes the pane; a failure stays on screen so its message can be read.
            let code = status >> 8 & 0xff != 0 ? status >> 8 & 0xff : status
            if host != nil, SSHExitDiagnosis.refusedLogin(exitCode: code, output: text()) {
                onRefusedLogin?()
                return
            }
            guard status == 0 else {
                showError("Exited with status \(status >> 8 & 0xff != 0 ? status >> 8 & 0xff : status). Ctrl+Shift+W closes this pane.")
                return
            }
            onExit?(status)
        }
        on(widget, "window-title-changed") { [weak self] in
            guard let self else { return }
            if let t = vte_terminal_get_window_title(terminal), t.pointee != 0 { title = String(cString: t) }
            titleState.terminalTitle = title // OSC 0/2
            onTitle?()
        }
        on(widget, "current-directory-uri-changed") { [weak self] in
            guard let self else { return }
            titleState.setDirectoryURI(vte_terminal_get_current_directory_uri(terminal).map { String(cString: $0) }) // OSC 7
            onTitle?()
        }
        onFocusEnter(widget) { [weak self] in
            self?.lastFocused = Date()
            self?.onFocus?()
        }
        onCommitted(widget) { [weak self] text in
            guard let self, !suppressBroadcast else { return }
            onCommit?(text)
        }
        on(badge, "clicked") { [weak self] in self?.onBadgeClicked?() }
        onRightClick(widget) { [weak self] x, y in self?.onContextMenu?(x, y) }

        if let plan { start(plan) } else { note("Waiting for the vault to unlock…") }
    }

    private(set) var started = false

    func start(_ plan: Result<SpawnPlan, SpawnError>) {
        guard !started else { return }
        started = true
        switch plan {
        case .success(let p):
            title = p.title
            onTitle?()
            spawn(p)
        case .failure(let error):
            showError(error.errorDescription ?? "\(error)")
        }
    }

    private func note(_ message: String) {
        var bytes = Array("\u{1b}[2m[rSshTerm] \(message)\u{1b}[0m\r\n".utf8CString.dropLast())
        vte_terminal_feed(terminal, &bytes, gssize(bytes.count))
    }

    deinit {
        if pid > 0, !exited { kill(pid, SIGHUP) }
        g_object_unref(widget.gptr)
        g_object_unref(container.gptr)
    }

    /// The striped background and badge of a pane in the broadcast (`indicator` off: the badge only). `source`:
    /// the pane typed in, whose badge stops broadcasting.
    func setReceiving(_ receiving: Bool, source: Bool = false, indicator: Bool) {
        gtk_widget_set_visible(badge, receiving ? 1 : 0)
        gtk_widget_set_tooltip_text(badge, Self.badgeTip(source: source))
        gtk_widget_set_visible(hatch, receiving && indicator ? 1 : 0)
        gtk_widget_queue_draw(hatch) // the pane may have moved in the window: the bands' phase follows
    }

    static func badgeTip(source: Bool) -> String {
        source ? "Broadcasting from this pane: click to stop broadcasting"
            : "In the broadcast: click to stop sending to this pane"
    }

    /// Where the stripes are and how big (the smoke test checks they fill the pane): the hatch's allocation, its
    /// origin in the window, and the pane's size.
    var hatchGeometry: (visible: Bool, x: Double, y: Double, width: Int32, height: Int32, paneWidth: Int32, paneHeight: Int32) {
        let origin = windowOrigin(of: hatch)
        return (gtk_widget_get_visible(hatch) != 0, origin.x, origin.y, gtk_widget_get_width(hatch),
                gtk_widget_get_height(hatch), gtk_widget_get_width(container), gtk_widget_get_height(container))
    }

    private func windowOrigin(of w: Widget) -> (x: Double, y: Double) {
        guard let root = gtk_widget_get_root(w) else { return (0, 0) }
        var from = graphene_point_t(x: 0, y: 0), to = graphene_point_t(x: 0, y: 0)
        guard gtk_widget_compute_point(w, cast(root), &from, &to) != 0 else { return (0, 0) }
        return (Double(to.x), Double(to.y))
    }

    /// The bands over this pane: `BroadcastPattern` in the hatch's own allocation, phase from its place in the
    /// window, band width from the font's line height.
    private func drawHatch(_ cr: OpaquePointer?, width: Double, height: Double) {
        guard let cr else { return }
        let look = BroadcastPattern.standard
        let tone = look.tone(darkBackground: darkBackground)
        let line = Double(vte_terminal_get_char_height(terminal))
        let origin = windowOrigin(of: hatch)
        cairo_rectangle(cr, 0, 0, width, height)
        cairo_clip(cr)
        cairo_set_source_rgba(cr, tone.red, tone.green, tone.blue, tone.opacity)
        cairo_set_line_width(cr, look.stripeWidth(lineHeight: line))
        for seg in look.stripes(origin: origin, width: width, height: height, lineHeight: line, yUp: false) {
            cairo_move_to(cr, seg.x0, seg.y0)
            cairo_line_to(cr, seg.x1, seg.y1)
        }
        cairo_stroke(cr)
    }

    /// Font, scrollback and colours from the settings: the server's theme, else the Preferences dark theme, else
    /// (style forced light) the Preferences light theme.
    func apply(_ settings: AppSettings, dark: Bool) {
        let look = TerminalAppearance.resolve(defaultFont: settings.fontName, server: server)
        let font = pango_font_description_from_string(look.font)
        vte_terminal_set_font(terminal, font)
        pango_font_description_free(font)
        vte_terminal_set_scrollback_lines(terminal, glong(settings.scrollbackLines))
        var fg = GdkRGBA(), bg = GdkRGBA()
        let scheme = look.scheme ?? settings.terminalScheme
        // The theme's 16 ANSI colours, foreground, background, cursor.
        _ = gdk_rgba_parse(&fg, scheme.foreground)
        _ = gdk_rgba_parse(&bg, scheme.background)
        darkBackground = BroadcastPattern.isDark(hex: scheme.background)
        gtk_widget_queue_draw(hatch)
        var palette = scheme.ansi.prefix(16).map { hex -> GdkRGBA in
            var c = GdkRGBA()
            _ = gdk_rgba_parse(&c, hex)
            return c
        }
        vte_terminal_set_colors(terminal, &fg, &bg, &palette, gsize(palette.count))
        var cursor = GdkRGBA()
        if gdk_rgba_parse(&cursor, scheme.cursor) != 0 { vte_terminal_set_color_cursor(terminal, &cursor) }
    }

    /// What the tab title templates read: OSC 0/2, OSC 7 and (local panes) the foreground process.
    private(set) var titleState = PaneTitleState()

    /// Reads the job in front of a local pane's shell (and the folder) from VTE's PTY; true when it changed.
    func pollForeground(user: String?, host: String?, home: String?) -> Bool {
        guard self.host == nil, server == nil, pid > 0, !exited, let pty = vte_terminal_get_pty(terminal) else { return false }
        let facts = ForegroundProcess.localFacts(masterFD: vte_pty_get_fd(pty), shellPID: pid, user: user, host: host, home: home)
        guard facts != titleState.local else { return false }
        titleState.local = facts
        return true
    }

    /// The working directory the shell reported (OSC 7), as a path.
    /// For a local shell without OSC 7 (no vte.sh in its profile), the shell process's own working directory.
    var directory: String? {
        if let uri = vte_terminal_get_current_directory_uri(terminal), let path = URL(string: String(cString: uri))?.path {
            return path
        }
        guard host == nil, pid > 0, !exited else { return nil }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd")
    }

    /// The last OSC 7 directory the shell reported ("file://host/path"), parsed.
    var shellDirectory: ShellDirectory? {
        guard let uri = vte_terminal_get_current_directory_uri(terminal) else { return nil }
        return ShellDirectory.parse(osc7: String(cString: uri))
    }

    func grabFocus() { gtk_widget_grab_focus(widget) }

    /// Pastes `text` (bracketed paste when the program asked for it) without re-broadcasting it.
    func paste(_ text: String) {
        suppressBroadcast = true
        vte_terminal_paste_text(terminal, text)
        suppressBroadcast = false
    }

    /// Types `text` into the child, as if from the keyboard (broadcast input).
    func send(_ text: String) {
        var bytes = Array(text.utf8CString.dropLast())
        // feed_child emits "commit" like typing does: without this the receivers would broadcast it back.
        suppressBroadcast = true
        vte_terminal_feed_child(terminal, &bytes, gssize(bytes.count))
        suppressBroadcast = false
    }

    func copy() { vte_terminal_copy_clipboard_format(terminal, VTE_FORMAT_TEXT) }
    func paste() { vte_terminal_paste_clipboard(terminal) }

    /// The visible screen and scrollback as text (the smoke test reads it back).
    func text() -> String {
        guard let raw = vte_terminal_get_text_format(terminal, VTE_FORMAT_TEXT) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    /// Runs `plan` again in this pane (another login after a refused one); the old output stays above it.
    func restart(_ plan: SpawnPlan) {
        guard exited else { return }
        exited = false
        pid = -1
        hideBar()
        note("Connecting again…")
        spawn(plan)
    }

    /// A bar over the bottom of the pane: `message` and buttons (title, suggested, action), left to right.
    func showBar(_ message: String, buttons: [(String, Bool, VoidHandler)]) {
        hideBar()
        let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        for c in ["toolbar", "osd", "login-bar"] { gtk_widget_add_css_class(box, c) }
        gtk_widget_set_valign(box, GTK_ALIGN_END)
        gtk_widget_set_halign(box, GTK_ALIGN_FILL)
        setMargins(box, 8)
        let text = label(message, wrap: true)
        gtk_widget_set_hexpand(text, 1)
        gtk_label_set_xalign(cast(text), 0)
        gtk_box_append(cast(box), text)
        for (title, suggested, action) in buttons {
            gtk_box_append(cast(box), button(title, css: suggested ? ["suggested-action", "pill"] : ["pill"], action))
        }
        gtk_overlay_add_overlay(cast(container), box)
        bar = box
    }

    func hideBar() {
        guard let bar else { return }
        gtk_overlay_remove_overlay(cast(container), bar)
        self.bar = nil
    }

    /// The bar's message, for the smoke test.
    var barText: String? {
        guard let bar, let first = gtk_widget_get_first_child(bar) else { return nil }
        return string(gtk_label_get_text(cast(first)))
    }

    private func showError(_ message: String) {
        var bytes = Array("\r\n\u{1b}[31m[rSshTerm] \(message)\u{1b}[0m\r\n".utf8CString.dropLast())
        vte_terminal_feed(terminal, &bytes, gssize(bytes.count))
        exited = true
    }

    /// VTE spawns on its own PTY. G_SPAWN_FILE_AND_ARGV_ZERO keeps argv[0] as planned ("-bash" makes a login shell).
    private func spawn(_ plan: SpawnPlan) {
        var argv: [UnsafeMutablePointer<CChar>?] = ([plan.executable] + plan.argv).map { strdup($0) } + [nil]
        var envv: [UnsafeMutablePointer<CChar>?] = plan.environmentList.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envv.forEach { free($0) }
        }
        let callback: VteTerminalSpawnAsyncCallback = { _, pid, error, data in
            let pane = Unmanaged<TerminalPane>.fromOpaque(data!).takeRetainedValue()
            if let error {
                pane.showError("Could not start: \(String(cString: error.pointee.message))")
            } else {
                pane.pid = pid
            }
        }
        let me = Unmanaged.passRetained(self).toOpaque()
        let flags = GSpawnFlags(rawValue: G_SPAWN_SEARCH_PATH_FROM_ENVP.rawValue | G_SPAWN_FILE_AND_ARGV_ZERO.rawValue)
        argv.withUnsafeMutableBufferPointer { a in
            envv.withUnsafeMutableBufferPointer { e in
                vte_terminal_spawn_async(terminal, VTE_PTY_DEFAULT, plan.directory, a.baseAddress!, e.baseAddress, flags,
                                         nil, nil, nil, -1, nil, callback, me)
            }
        }
    }
}
