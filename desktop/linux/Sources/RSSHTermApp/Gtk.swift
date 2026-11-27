// The thin layer between Swift and GObject: pointer casts (GTK's cast macros are not importable), signal handlers
// as Swift closures, and hops onto the GTK main loop. Everything here runs on the main thread.
import CGtk
import Foundation

// MARK: - Pointers

/// Anything that is a GObject pointer, whatever Swift made of its C type (typed, opaque or raw).
protocol GPtr { var gptr: UnsafeMutableRawPointer? { get } }
extension UnsafeMutablePointer: GPtr { var gptr: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(self) } }
extension OpaquePointer: GPtr { var gptr: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(self) } }
extension UnsafeMutableRawPointer: GPtr { var gptr: UnsafeMutableRawPointer? { self } }
extension Optional: GPtr where Wrapped: GPtr { var gptr: UnsafeMutableRawPointer? { self?.gptr ?? nil } }

protocol GPtrInit { init(gptr: UnsafeMutableRawPointer) }
extension UnsafeMutablePointer: GPtrInit { init(gptr: UnsafeMutableRawPointer) { self = gptr.assumingMemoryBound(to: Pointee.self) } }
extension OpaquePointer: GPtrInit { init(gptr: UnsafeMutableRawPointer) { self.init(gptr) } }
extension UnsafeMutableRawPointer: GPtrInit { init(gptr: UnsafeMutableRawPointer) { self = gptr } }
extension Optional: GPtrInit where Wrapped: GPtrInit { init(gptr: UnsafeMutableRawPointer) { self = .some(Wrapped(gptr: gptr)) } }

/// `GTK_WINDOW(w)` and friends: the type comes from the parameter it is passed to.
func cast<T: GPtrInit>(_ p: (any GPtr)?) -> T {
    guard let raw = p?.gptr else { fatalError("cast of a NULL GObject pointer") }
    return T(gptr: raw)
}

typealias Widget = UnsafeMutablePointer<GtkWidget>

/// A C string from GLib (not freed here).
func string(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }

// MARK: - Signals

private final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

private func retained<T>(_ value: T) -> gpointer { Unmanaged.passRetained(Box(value)).toOpaque() }
private func unbox<T>(_ data: gpointer?) -> T { Unmanaged<Box<T>>.fromOpaque(data!).takeUnretainedValue().value }

private let releaseBox: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<AnyObject>.fromOpaque(data).release()
}

@discardableResult
private func connect(_ instance: (any GPtr)?, _ signal: String, _ callback: GCallback, _ data: gpointer,
                     after: Bool = false) -> gulong {
    g_signal_connect_data(instance?.gptr, signal, callback, data, releaseBox, after ? G_CONNECT_AFTER : GConnectFlags(0))
}

// GLib calls every handler on the main thread (the GTK thread), which is the main actor's.
typealias VoidHandler = @MainActor () -> Void
typealias PointerHandler = @MainActor (gpointer?) -> Void
typealias PointerBoolHandler = @MainActor (gpointer?) -> Bool
typealias IntHandler = @MainActor (Int32) -> Void
typealias KeyHandler = @MainActor (_ keyval: UInt32, _ state: UInt32) -> Bool
typealias DropHandler = @MainActor (UnsafePointer<GValue>?, Double, Double) -> Bool
typealias PressHandler = @MainActor (Int32, Double, Double) -> Void
typealias PrepareHandler = @MainActor (Double, Double) -> OpaquePointer?
typealias TextHandler = @MainActor (String) -> Void

/// Runs `body` as main-actor code from a GLib callback (always on the main thread).
@inline(__always)
func onGTK<T>(_ body: @MainActor () -> T) -> T { MainActor.assumeIsolated(body) }

/// Signals with no arguments: `clicked`, `activate`, `search-changed`, `close-request` (returns FALSE).
@discardableResult
func on(_ instance: (any GPtr)?, _ signal: String, _ handler: @escaping VoidHandler) -> gulong {
    let cb: @convention(c) (gpointer?, gpointer?) -> Void = { _, data in
        onGTK { (unbox(data) as VoidHandler)() }
    }
    return connect(instance, signal, unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// `notify::<property>`: the GParamSpec argument is ignored.
@discardableResult
func onNotify(_ instance: (any GPtr)?, _ property: String, _ handler: @escaping VoidHandler) -> gulong {
    onPointer(instance, "notify::\(property)") { _ in handler() }
}

/// Signals with one pointer argument: `response` (const char *), `row-activated` (GtkListBoxRow *),
/// GSimpleAction `activate` (GVariant *).
@discardableResult
func onPointer(_ instance: (any GPtr)?, _ signal: String, _ handler: @escaping PointerHandler) -> gulong {
    let cb: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, arg, data in
        onGTK { (unbox(data) as PointerHandler)(arg) }
    }
    return connect(instance, signal, unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// Signals with one pointer argument that return a gboolean: AdwTabView `close-page`.
@discardableResult
func onPointerBool(_ instance: (any GPtr)?, _ signal: String, _ handler: @escaping PointerBoolHandler) -> gulong {
    let cb: @convention(c) (gpointer?, gpointer?, gpointer?) -> gboolean = { _, arg, data in
        onGTK { (unbox(data) as PointerBoolHandler)(arg) } ? 1 : 0
    }
    return connect(instance, signal, unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// VTE `child-exited` (int status).
@discardableResult
func onInt(_ instance: (any GPtr)?, _ signal: String, _ handler: @escaping IntHandler) -> gulong {
    let cb: @convention(c) (gpointer?, Int32, gpointer?) -> Void = { _, value, data in
        onGTK { (unbox(data) as IntHandler)(value) }
    }
    return connect(instance, signal, unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// VTE `commit` (const char *text, guint size): what the user typed, as bytes for the child.
@discardableResult
func onCommitted(_ instance: (any GPtr)?, _ handler: @escaping TextHandler) -> gulong {
    let cb: @convention(c) (gpointer?, UnsafePointer<CChar>?, guint, gpointer?) -> Void = { _, text, size, data in
        guard let text else { return }
        let bytes = UnsafeRawBufferPointer(start: text, count: Int(size))
        let typed = String(decoding: bytes, as: UTF8.self)
        onGTK { (unbox(data) as TextHandler)(typed) }
    }
    return connect(instance, "commit", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// Whether `instance` is a `type` (G_TYPE_CHECK_INSTANCE_TYPE).
func isA(_ instance: (any GPtr)?, _ type: GType) -> Bool {
    guard let raw = instance?.gptr else { return false }
    return g_type_check_instance_is_a(raw.assumingMemoryBound(to: GTypeInstance.self), type) != 0
}

/// GtkEventControllerKey `key-pressed`; return true to stop the event.
@discardableResult
func onKeyPressed(_ controller: (any GPtr)?, _ handler: @escaping KeyHandler) -> gulong {
    let cb: @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> gboolean = { _, keyval, _, state, data in
        onGTK { (unbox(data) as KeyHandler)(keyval, state.rawValue) } ? 1 : 0
    }
    return connect(controller, "key-pressed", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// A capture-phase key controller on `widget`: sees keys before the focused child (the terminal) does.
func addKeyHandler(_ widget: (any GPtr)?, capture: Bool = true, _ handler: @escaping KeyHandler) {
    let controller = gtk_event_controller_key_new()
    if capture { gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE) }
    onKeyPressed(controller, handler)
    gtk_widget_add_controller(cast(widget), controller)
}

/// Called when `widget` (or a child) gets keyboard focus.
func onFocusEnter(_ widget: (any GPtr)?, _ handler: @escaping VoidHandler) {
    let controller = gtk_event_controller_focus_new()
    on(controller, "enter", handler)
    gtk_widget_add_controller(cast(widget), controller)
}

// MARK: - Main loop

/// Runs `work` on the GTK main loop (from any thread).
func onMain(_ work: @escaping @MainActor () -> Void) {
    let cb: @convention(c) (gpointer?) -> gboolean = { data in
        onGTK { (unbox(data) as @MainActor () -> Void)() }
        return 0 // G_SOURCE_REMOVE
    }
    g_idle_add_full(G_PRIORITY_DEFAULT, cb, retained(work), { data in
        guard let data else { return }
        Unmanaged<AnyObject>.fromOpaque(data).release()
    })
}

/// Calls `work` every `seconds` on the main loop while it returns true.
func every(seconds: UInt32, _ work: @escaping @MainActor () -> Bool) {
    let cb: @convention(c) (gpointer?) -> gboolean = { data in onGTK { (unbox(data) as @MainActor () -> Bool)() } ? 1 : 0 }
    g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, seconds, cb, retained(work), { data in
        guard let data else { return }
        Unmanaged<AnyObject>.fromOpaque(data).release()
    })
}

/// Calls `work` every `milliseconds` on the main loop while it returns true.
func every(milliseconds: UInt32, _ work: @escaping @MainActor () -> Bool) {
    let cb: @convention(c) (gpointer?) -> gboolean = { data in onGTK { (unbox(data) as @MainActor () -> Bool)() } ? 1 : 0 }
    g_timeout_add_full(G_PRIORITY_DEFAULT, milliseconds, cb, retained(work), { data in
        guard let data else { return }
        Unmanaged<AnyObject>.fromOpaque(data).release()
    })
}

/// Runs async `work` off the main thread and hands its result back on the main loop.
func background<T>(_ work: @escaping @Sendable () async -> T, then done: @escaping @MainActor (T) -> Void) {
    let finish = UncheckedBox(done)
    Task.detached {
        let result = await work()
        let carried = UncheckedBox(result)
        onMain { finish.value(carried.value) }
    }
}

/// Moves a value across the Task boundary; the GTK side only touches it on the main loop.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Small widget helpers

func label(_ text: String, css: [String] = [], wrap: Bool = false) -> Widget {
    let l = gtk_label_new(text)!
    for c in css { gtk_widget_add_css_class(l, c) }
    if wrap {
        gtk_label_set_wrap(cast(l), 1)
        gtk_label_set_xalign(cast(l), 0)
    }
    return l
}

func iconButton(_ icon: String, tooltip: String, _ action: @escaping VoidHandler) -> Widget {
    let b = gtk_button_new_from_icon_name(icon)!
    gtk_widget_set_tooltip_text(b, tooltip)
    on(b, "clicked", action)
    return b
}

func copyToClipboard(_ text: String, from widget: (any GPtr)?) {
    gdk_clipboard_set_text(gtk_widget_get_clipboard(cast(widget)), text)
}

// MARK: - Drag and drop, clicks, menus

/// GtkDropTarget `drop` (const GValue *value, double x, double y) -> gboolean.
@discardableResult
func onDrop(_ target: (any GPtr)?, _ handler: @escaping DropHandler) -> gulong {
    let cb: @convention(c) (gpointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, value, x, y, data in
        onGTK { (unbox(data) as DropHandler)(value, x, y) } ? 1 : 0
    }
    return connect(target, "drop", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// GtkGestureClick `pressed` (int n_press, double x, double y).
@discardableResult
func onPressed(_ gesture: (any GPtr)?, _ handler: @escaping PressHandler) -> gulong {
    let cb: @convention(c) (gpointer?, Int32, Double, Double, gpointer?) -> Void = { _, n, x, y, data in
        onGTK { (unbox(data) as PressHandler)(n, x, y) }
    }
    return connect(gesture, "pressed", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// GtkDragSource `prepare` (double x, double y) -> GdkContentProvider* (or NULL to refuse the drag).
@discardableResult
func onDragPrepare(_ source: (any GPtr)?, _ handler: @escaping PrepareHandler) -> gulong {
    let cb: @convention(c) (gpointer?, Double, Double, gpointer?) -> OpaquePointer? = { _, x, y, data in
        onGTK { (unbox(data) as PrepareHandler)(x, y) }
    }
    return connect(source, "prepare", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// Calls `handler(x, y)` on a right click (button 3) on `widget`.
func onRightClick(_ widget: (any GPtr)?, _ handler: @escaping @MainActor (Double, Double) -> Void) {
    let gesture = gtk_gesture_click_new()
    gtk_gesture_single_set_button(cast(gesture), 3)
    onPressed(gesture) { _, x, y in handler(x, y) }
    gtk_widget_add_controller(cast(widget), cast(gesture))
}

/// A popover of flat buttons pointing at (x, y) in `widget`; it removes itself when closed.
func contextMenu(on widget: Widget, x: Double, y: Double, items: [(String, @MainActor () -> Void)]) {
    let popover = gtk_popover_new()!
    let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    for (title, action) in items {
        let button = gtk_button_new_with_label(title)!
        gtk_widget_add_css_class(button, "flat")
        gtk_widget_set_halign(gtk_button_get_child(cast(button)), GTK_ALIGN_START)
        on(button, "clicked") {
            gtk_popover_popdown(cast(popover))
            action()
        }
        gtk_box_append(cast(box), button)
    }
    gtk_popover_set_child(cast(popover), box)
    gtk_popover_set_has_arrow(cast(popover), 0)
    gtk_widget_set_parent(popover, widget)
    var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
    gtk_popover_set_pointing_to(cast(popover), &rect)
    on(popover, "closed") { onMain { gtk_widget_unparent(popover) } }
    gtk_popover_popup(cast(popover))
}

/// A content provider carrying `text` (in-app drags: server ids, file paths).
func textContent(_ text: String) -> OpaquePointer {
    let bytes = Array(text.utf8)
    let gbytes = bytes.withUnsafeBufferPointer { g_bytes_new($0.baseAddress, gsize($0.count)) }
    defer { g_bytes_unref(gbytes) }
    return OpaquePointer(gdk_content_provider_new_for_bytes("text/plain;charset=utf-8", gbytes))
}

/// G_TYPE_STRING (fundamental type 16).
let gTypeString: GType = 16 << 2

/// A GtkStringList from Swift strings.
func stringList(_ items: [String]) -> OpaquePointer {
    var c: [UnsafePointer<CChar>?] = items.map { UnsafePointer(strdup($0)) } + [nil]
    let list = gtk_string_list_new(&c)
    c.forEach { free(UnsafeMutablePointer(mutating: $0)) }
    return cast(list)
}

func setMargins(_ widget: Widget, _ value: Int32) {
    gtk_widget_set_margin_top(widget, value)
    gtk_widget_set_margin_bottom(widget, value)
    gtk_widget_set_margin_start(widget, value)
    gtk_widget_set_margin_end(widget, value)
}

func scrolled(_ child: Widget) -> Widget {
    let s = gtk_scrolled_window_new()!
    gtk_scrolled_window_set_child(cast(s), child)
    gtk_widget_set_vexpand(s, 1)
    return s
}

/// An AdwDialog with a header bar and `content` (scrolls when `scroll`).
func makeDialog(title: String, width: Int32, height: Int32, content: Widget, headerEnd: [Widget] = [],
                headerStart: [Widget] = []) -> Widget {
    let dialog: Widget = cast(adw_dialog_new())
    adw_dialog_set_title(cast(dialog), title)
    adw_dialog_set_content_width(cast(dialog), width)
    adw_dialog_set_content_height(cast(dialog), height)
    let header = adw_header_bar_new()!
    for w in headerEnd { adw_header_bar_pack_end(cast(header), w) }
    for w in headerStart { adw_header_bar_pack_start(cast(header), w) }
    let toolbar = adw_toolbar_view_new()!
    adw_toolbar_view_add_top_bar(cast(toolbar), header)
    adw_toolbar_view_set_content(cast(toolbar), content)
    adw_dialog_set_child(cast(dialog), toolbar)
    return dialog
}

func button(_ title: String, css: [String] = [], _ action: @escaping VoidHandler) -> Widget {
    let b = gtk_button_new_with_label(title)!
    for c in css { gtk_widget_add_css_class(b, c) }
    on(b, "clicked", action)
    return b
}

/// An AdwEntryRow with `text`; `changed` gets every edit.
func entryRow(_ title: String, text: String, changed: @escaping @MainActor (String) -> Void) -> Widget {
    let row = adw_entry_row_new()!
    adw_preferences_row_set_title(cast(row), title)
    gtk_editable_set_text(cast(row), text)
    on(row, "changed") { changed(string(gtk_editable_get_text(cast(row)))) }
    return row
}

/// An AdwComboRow over `titles`; `chosen` gets the index.
func comboRow(_ title: String, titles: [String], selected: Int, chosen: @escaping @MainActor (Int) -> Void) -> Widget {
    let row = adw_combo_row_new()!
    adw_preferences_row_set_title(cast(row), title)
    adw_combo_row_set_model(cast(row), cast(stringList(titles)))
    adw_combo_row_set_selected(cast(row), guint(max(selected, 0)))
    onNotify(row, "selected") { chosen(Int(adw_combo_row_get_selected(cast(row)))) }
    return row
}

// MARK: - Pointer and key input (remote screens)

typealias PointHandler = @MainActor (Double, Double) -> Void

/// GtkEventControllerMotion `motion` (double x, double y).
@discardableResult
func onMotion(_ controller: (any GPtr)?, _ handler: @escaping PointHandler) -> gulong {
    let cb: @convention(c) (gpointer?, Double, Double, gpointer?) -> Void = { _, x, y, data in
        onGTK { (unbox(data) as PointHandler)(x, y) }
    }
    return connect(controller, "motion", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

/// GtkGestureClick `released` (int n_press, double x, double y).
@discardableResult
func onReleased(_ gesture: (any GPtr)?, _ handler: @escaping PressHandler) -> gulong {
    let cb: @convention(c) (gpointer?, Int32, Double, Double, gpointer?) -> Void = { _, n, x, y, data in
        onGTK { (unbox(data) as PressHandler)(n, x, y) }
    }
    return connect(gesture, "released", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

typealias ScrollHandler = @MainActor (Double, Double) -> Bool

/// GtkEventControllerScroll `scroll` (double dx, double dy) -> gboolean.
@discardableResult
func onScroll(_ controller: (any GPtr)?, _ handler: @escaping ScrollHandler) -> gulong {
    let cb: @convention(c) (gpointer?, Double, Double, gpointer?) -> gboolean = { _, dx, dy, data in
        onGTK { (unbox(data) as ScrollHandler)(dx, dy) } ? 1 : 0
    }
    return connect(controller, "scroll", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

typealias KeyUpHandler = @MainActor (_ keyval: UInt32, _ state: UInt32) -> Void

/// GtkEventControllerKey `key-released` (guint keyval, guint keycode, GdkModifierType state).
@discardableResult
func onKeyReleased(_ controller: (any GPtr)?, _ handler: @escaping KeyUpHandler) -> gulong {
    let cb: @convention(c) (gpointer?, guint, guint, GdkModifierType, gpointer?) -> Void = { _, keyval, _, state, data in
        onGTK { (unbox(data) as KeyUpHandler)(keyval, state.rawValue) }
    }
    return connect(controller, "key-released", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

// MARK: - Drawing

typealias DrawHandler = @MainActor (OpaquePointer?, Int32, Int32) -> Void

/// GtkDrawingArea's draw function (cairo_t, width, height); the closure is released with the area.
func setDrawFunc(_ area: Widget, _ handler: @escaping DrawHandler) {
    let cb: @convention(c) (UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, gpointer?) -> Void = {
        _, cr, w, h, data in onGTK { (unbox(data) as DrawHandler)(cr, w, h) }
    }
    let release: GDestroyNotify = { data in
        guard let data else { return }
        Unmanaged<AnyObject>.fromOpaque(data).release()
    }
    gtk_drawing_area_set_draw_func(cast(area), cb, retained(handler), release)
}
