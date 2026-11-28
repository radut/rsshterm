// The look and feel of a pane or tab drag (iTerm2's): a half-size translucent snapshot of the real content under
// the pointer, the source dimmed, the target's half (or the whole pane for a swap) highlighted and animated, the
// tab strip opening a gap where the tab will go. Where it lands comes from RSSHDesktopCore DragDrop.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHTermLinux

/// Pane and tab drags offer every action: Ctrl and Shift (Ctrl+Shift+Alt starts a drag anywhere in a pane) make GTK
/// ask for copy or link, and the drop is a move whatever it asks.
let paneDragActions = GdkDragAction(rawValue: GDK_ACTION_MOVE.rawValue | GDK_ACTION_COPY.rawValue | GDK_ACTION_LINK.rawValue)

/// The snapshot's longest side, in pixels.
private let dragImageMaxSide = 420.0
/// The snapshot's opacity.
private let dragImageOpacity = 0.6

/// A static, half-size, translucent picture of `widget` as it is now, and its scale; nil before it has a size.
@MainActor
func dragImage(of widget: Widget) -> (paintable: OpaquePointer, scale: Double)? {
    let w = Double(gtk_widget_get_width(widget)), h = Double(gtk_widget_get_height(widget))
    guard w > 1, h > 1, let live = gtk_widget_paintable_new(widget) else { return nil }
    defer { g_object_unref(live.gptr) }
    guard let image = gdk_paintable_get_current_image(live) else { return nil }
    defer { g_object_unref(image.gptr) }
    let size = DragDrop.imageSize(pane: .init(width: w, height: h), maxSide: dragImageMaxSide)
    let snap = gtk_snapshot_new()!
    gtk_snapshot_push_opacity(snap, dragImageOpacity)
    gdk_paintable_snapshot(image, cast(snap), size.width, size.height)
    gtk_snapshot_pop(snap)
    var bounds = graphene_size_t(width: Float(size.width), height: Float(size.height))
    guard let paintable = gtk_snapshot_free_to_paintable(snap, &bounds) else { return nil }
    return (paintable, size.width / w)
}

/// What `installDrag` asks of the pane or tab being dragged.
struct DragSourceSpec {
    /// What is dragged; nil refuses the drag.
    let item: @MainActor () -> DragDrop.Item?
    /// The widget whose picture follows the pointer and which dims while it is away.
    let picture: @MainActor () -> Widget?
    /// The app running the drag (the window holding the pane may change between drags).
    let app: @MainActor () -> AppController?
    /// Only with these modifiers held (Ctrl+Shift+Alt anywhere in a pane); nil = always.
    var modifiers: UInt32?
    /// Ahead of the widget's ancestors: a tab sits in a header bar, which would move the window instead.
    var capture = false
}

/// A drag source on `widget` for a pane or a tab.
@MainActor
func installDrag(on widget: Widget, _ spec: DragSourceSpec) {
    let drag = gtk_drag_source_new()!
    gtk_drag_source_set_actions(drag, paneDragActions)
    if spec.modifiers != nil || spec.capture {
        // Before the terminal sees the press, but only taken once the drag starts with the modifiers held.
        gtk_event_controller_set_propagation_phase(cast(drag), GTK_PHASE_CAPTURE)
    }
    onDragPrepare(drag) { x, y in
        if let needed = spec.modifiers {
            let state = gtk_event_controller_get_current_event_state(cast(drag)).rawValue
            guard state & needed == needed else { return nil }
        }
        guard let item = spec.item(), let app = spec.app() else { return nil }
        let picture = spec.picture()
        if let picture, let (paintable, scale) = dragImage(of: picture) {
            var from = graphene_point_t(x: Float(x), y: Float(y)), to = graphene_point_t()
            if gtk_widget_compute_point(widget, picture, &from, &to) == 0 { to = from }
            gtk_drag_source_set_icon(drag, paintable, Int32(Double(to.x) * scale), Int32(Double(to.y) * scale))
            g_object_unref(paintable.gptr)
        }
        app.dragStarted(item, dimming: picture)
        return textContent(DragPayload(item).text)
    }
    onDragCancelWithDrag(drag) { reason, gdkDrag in
        guard let app = spec.app(), let item = spec.item() else { return false }
        return app.dragCancelled(item, reason: reason, drag: gdkDrag)
    }
    onDragEnd(drag) { spec.app()?.dragEnded() }
    gtk_widget_add_controller(widget, cast(drag))
}

extension DragPayload {
    init(_ item: DragDrop.Item) {
        switch item {
        case .pane(let id): self = .pane(id)
        case .tab(let id): self = .tab(id)
        }
    }

    var item: DragDrop.Item {
        switch self {
        case .pane(let id): .pane(id)
        case .tab(let id): .tab(id)
        }
    }
}

/// GtkDragSource `drag-cancel` with the GdkDrag (to ask where the pointer is).
@discardableResult
func onDragCancelWithDrag(_ source: (any GPtr)?,
                          _ handler: @escaping @MainActor (GdkDragCancelReason, OpaquePointer?) -> Bool) -> gulong {
    typealias Handler = @MainActor (GdkDragCancelReason, OpaquePointer?) -> Bool
    let cb: @convention(c) (gpointer?, gpointer?, GdkDragCancelReason, gpointer?) -> gboolean = { _, drag, reason, data in
        onGTK { (unbox(data) as Handler)(reason, drag.map { OpaquePointer($0) }) } ? 1 : 0
    }
    return connect(source, "drag-cancel", unsafeBitCast(cb, to: GCallback.self), retained(handler))
}

// MARK: - Animations (libadwaita's frame-clock animations: smooth at the display's rate)

/// Runs `step(t)` with t from 0 to 1, ease-out, over `ms` milliseconds on `widget`'s frame clock; a new run stops
/// the one before.
@MainActor
final class Tween {
    private var animation: OpaquePointer?

    func run(on widget: Widget, ms: UInt32, _ step: @escaping @MainActor (Double) -> Void) {
        stop()
        let cb: AdwAnimationTargetFunc = { value, data in onGTK { (unbox(data) as @MainActor (Double) -> Void)(value) } }
        let release: GDestroyNotify = { data in
            guard let data else { return }
            Unmanaged<AnyObject>.fromOpaque(data).release()
        }
        let target = adw_callback_animation_target_new(cb, retained(step), release)
        let a = adw_timed_animation_new(widget, 0, 1, ms, target)!
        adw_timed_animation_set_easing(cast(a), ADW_EASE_OUT_CUBIC)
        animation = OpaquePointer(a)
        adw_animation_play(a)
    }

    func stop() {
        guard let a = animation else { return }
        animation = nil
        adw_animation_pause(cast(a))
        g_object_unref(a.gptr)
    }
}

/// A gap in the tab strip where a dragged tab will go; it holds its own reference, so an animation step never
/// touches a freed widget.
@MainActor
final class StripGap {
    let widget: Widget
    let tween = Tween()
    private(set) var disposed = false

    init() {
        widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        g_object_ref_sink(widget.gptr)
        gtk_widget_add_css_class(widget, "tab-drop-slot")
        gtk_widget_set_can_target(widget, 0)
        gtk_widget_set_size_request(widget, 0, -1)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        tween.stop()
        if let parent = gtk_widget_get_parent(widget) { gtk_box_remove(cast(parent), widget) }
        g_object_unref(widget.gptr)
    }
}

func lerp(_ a: UnitRect, _ b: UnitRect, _ t: Double) -> UnitRect {
    UnitRect(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, width: a.width + (b.width - a.width) * t,
             height: a.height + (b.height - a.height) * t)
}

// MARK: - The window's side: highlight, tab strip gap, dimmed source

extension MainWindow {
    static let dragCSS = """
        .drag-source { opacity: 0.4; }
        .tab-drop-slot { background-color: alpha(@accent_bg_color, 0.22); border: 2px dashed @accent_bg_color; border-radius: 8px; }
        """

    /// Shows the highlight over `rect` (unit square of the pane area), sliding from where it was; nil hides it.
    func showHighlight(_ rect: UnitRect?) {
        guard let rect else {
            highlightTween.stop()
            highlightRect = nil
            gtk_widget_set_visible(preview, 0)
            return
        }
        guard rect != highlightTarget || highlightRect == nil else { return }
        highlightTarget = rect
        // From nothing it grows out of the target's middle.
        let from = highlightRect ?? UnitRect(x: rect.midX - rect.width * 0.4, y: rect.midY - rect.height * 0.4,
                                             width: rect.width * 0.8, height: rect.height * 0.8)
        highlightRect = from
        placeHighlight(from)
        highlightTween.run(on: catcher, ms: 120) { [weak self] t in
            guard let self else { return }
            let now = lerp(from, rect, t)
            highlightRect = now
            placeHighlight(now)
        }
    }

    private func placeHighlight(_ rect: UnitRect) {
        let w = Double(gtk_widget_get_width(catcher)), h = Double(gtk_widget_get_height(catcher))
        gtk_fixed_move(cast(catcher), preview, rect.x * w, rect.y * h)
        gtk_widget_set_size_request(preview, Int32(max(1, rect.width * w)), Int32(max(1, rect.height * h)))
        gtk_widget_set_visible(preview, 1)
    }

    /// The strip's tab buttons, in order (not the gaps).
    var tabItems: [Widget] {
        var items: [Widget] = []
        var child = gtk_widget_get_first_child(tabStrip)
        while let c = child {
            if !gtk_widget_has_css_class(c, "tab-drop-slot").bool { items.append(c) }
            child = gtk_widget_get_next_sibling(c)
        }
        return items
    }

    /// The tab spans along the strip as they are without the gap, so the slot does not jump as the gap opens.
    func tabSpans() -> [TabInsertion.Span] {
        var spans: [TabInsertion.Span] = []
        var shift = 0.0
        var child = gtk_widget_get_first_child(tabStrip)
        while let c = child {
            var r = graphene_rect_t()
            _ = gtk_widget_compute_bounds(c, tabStrip, &r)
            if gtk_widget_has_css_class(c, "tab-drop-slot").bool {
                shift += Double(r.size.width) + 4 // the strip's spacing
            } else {
                spans.append(.init(x: Double(r.origin.x) - shift, width: Double(r.size.width)))
            }
            child = gtk_widget_get_next_sibling(c)
        }
        return spans
    }

    /// The insertion slot at strip x (strip scroller coordinates).
    func tabSlot(stripX x: Double, strip: Widget) -> Int {
        var from = graphene_point_t(x: Float(x), y: 0), to = graphene_point_t()
        if gtk_widget_compute_point(strip, tabStrip, &from, &to) == 0 { to = from }
        return TabInsertion.slot(x: Double(to.x), frames: tabSpans())
    }

    /// Opens a gap at `slot` (nil closes it): the old gap shrinks away while the new one grows, so the neighbours
    /// slide. A tab next to its own place opens nothing (the drop would change nothing).
    func showTabGap(at slot: Int?, for item: DragDrop.Item?) {
        let own: Int? = if case .tab(let id)? = item { model?.tabIndex(of: id) } else { nil }
        let wanted = slot.flatMap { s in TabInsertion.destination(slot: s, dragged: own) == nil ? nil : s }
        guard wanted != gapSlot else { return }
        gapSlot = wanted
        if let old = gap {
            gap = nil
            closingGaps.append(old)
            let start = Double(gtk_widget_get_width(old.widget))
            old.tween.run(on: old.widget, ms: 140) { [weak self, weak old] t in
                guard let old, !old.disposed else { return }
                gtk_widget_set_size_request(old.widget, Int32(start * (1 - t)), -1)
                guard t >= 1 else { return }
                onMain { [weak self] in
                    old.dispose()
                    self?.closingGaps.removeAll { $0 === old }
                }
            }
        }
        guard let s = wanted else { return }
        let width: Double = if case .tab? = item { 180 } else { 110 }
        let new = StripGap()
        let items = tabItems
        gtk_box_insert_child_after(cast(tabStrip), new.widget, s > 0 && s <= items.count ? items[s - 1] : nil)
        gap = new
        new.tween.run(on: new.widget, ms: 140) { [weak new] t in
            guard let new, !new.disposed else { return }
            gtk_widget_set_size_request(new.widget, Int32(width * t), -1)
        }
    }

    /// Every gap out of the strip at once (before the strip is rebuilt).
    func removeTabGaps() {
        gap?.dispose()
        closingGaps.forEach { $0.dispose() }
        gap = nil
        gapSlot = nil
        closingGaps = []
    }

    /// For the smoke test's scripted drags: per pane of the selected tab, in order, its grip and its rectangle, in
    /// X window pixels: "gripX,gripY,x,y,width,height;…", then "|" and the tab items' centres "x,y;…".
    func dragPoints() -> String {
        guard let model else { return "" }
        // Window pixels from the X window's corner: past the client-side shadow.
        var sx = 0.0, sy = 0.0
        gtk_native_get_surface_transform(cast(window), &sx, &sy)
        func bounds(_ w: Widget) -> graphene_rect_t {
            var r = graphene_rect_t()
            _ = gtk_widget_compute_bounds(w, window, &r)
            r.origin.x += Float(sx)
            r.origin.y += Float(sy)
            return r
        }
        let panesPart = model.selectedTab.paneIDs.compactMap { id -> String? in
            guard let w = panes[id]?.container ?? screens[id]?.widget else { return nil }
            let r = bounds(w)
            let x = Int(r.origin.x), y = Int(r.origin.y), width = Int(r.size.width), height = Int(r.size.height)
            return "\(x + width / 2),\(y + 10),\(x),\(y),\(width),\(height)"
        }.joined(separator: ";")
        let tabsPart = tabItems.map { item -> String in
            let r = bounds(item)
            return "\(Int(r.origin.x + r.size.width / 2)),\(Int(r.origin.y + r.size.height / 2))"
        }.joined(separator: ";")
        return panesPart + "|" + tabsPart
    }

    /// Remembers whether a drag is over this window (a drop where nothing takes it then changes nothing; outside
    /// every window it opens a new one). The leave that ends a drop comes with it, so a leave counts a moment later.
    func trackDragHover() {
        let motion = gtk_drop_controller_motion_new()!
        on(motion, "enter") { [unowned self] in app.dragHover = self }
        on(motion, "leave") { [unowned self] in
            onMain { [weak self] in
                guard let self, app.dragHover === self else { return }
                app.dragHover = nil
            }
        }
        gtk_widget_add_controller(window, cast(motion))
    }

    /// The source pane or tab fades while it is away; the strip and highlight reset when the drag ends.
    func dragFinished() {
        showHighlight(nil)
        showTabGap(at: nil, for: nil)
    }
}

extension gboolean {
    var bool: Bool { self != 0 }
}
