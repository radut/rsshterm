// Moving panes and tabs (docs/desktop/moving-panes.md): drag and drop, the Move menus, the pick-a-target mode,
// tab colours. The layout changes come from RSSHDesktopCore LayoutMoves; this file finds targets and hands live
// panes (VTE terminals, screens) from one window to another without restarting them.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHTermLinux

/// What an in-app drag carries, as text (GtkDropTarget takes G_TYPE_STRING).
enum DragPayload: Equatable {
    case pane(PaneID)
    case tab(UUID)

    var text: String {
        switch self {
        case .pane(let id): "rsshterm-pane:" + id.raw.uuidString
        case .tab(let id): "rsshterm-tab:" + id.uuidString
        }
    }

    init?(text: String) {
        if text.hasPrefix("rsshterm-pane:"), let id = UUID(uuidString: String(text.dropFirst(14))) {
            self = .pane(PaneID(id))
        } else if text.hasPrefix("rsshterm-tab:"), let id = UUID(uuidString: String(text.dropFirst(13))) {
            self = .tab(id)
        } else {
            return nil
        }
    }

    init?(_ value: UnsafePointer<GValue>?) {
        guard let value, let raw = g_value_get_string(value) else { return nil }
        self.init(text: String(cString: raw))
    }
}

/// Live panes on their way from one window to another: still running, out of every widget tree.
final class PanePool {
    var terminals: [PaneID: TerminalPane] = [:]
    var screens: [PaneID: ScreenPane] = [:]
    var loginRetries: [PaneID: PaneLoginRetry] = [:]
}

extension MainWindow {
    static let moveCSS = """
        .drop-preview { background-color: alpha(@accent_bg_color, 0.30); border: 2px solid @accent_bg_color; border-radius: 6px; }
        .pane-grip { opacity: 0.35; padding: 2px; border-radius: 4px; background-color: alpha(black, 0.25); color: white; }
        .pane-grip:hover { opacity: 1; }
        .move-source { outline: 3px solid #2ec27e; outline-offset: -3px; }
        .move-source > vte-terminal { opacity: 0.7; }
        """ + TabColor.allCases.map {
            ".tab-strip .tab-item.tab-color-\($0.rawValue) { box-shadow: inset 0 -3px 0 \($0.hex); "
                + "background-color: alpha(\($0.hex), 0.18); }"
        }.joined(separator: "\n")

    // MARK: Handing panes over

    /// Panes `ids` leave this window: out of their widgets and dictionaries, still running, into `pool`.
    func handOver(_ ids: Set<PaneID>, to pool: PanePool) {
        for id in ids {
            if let t = panes.removeValue(forKey: id) {
                detach(t.container)
                pool.terminals[id] = t
            }
            if let s = screens.removeValue(forKey: id) {
                detach(s.widget)
                pool.screens[id] = s
            }
            if let r = loginRetries.removeValue(forKey: id) { pool.loginRetries[id] = r }
        }
    }

    /// Takes the pool's panes that `model` holds (before `setModel`, which then keeps them running).
    func adopt(_ pool: PanePool, for model: Window?) {
        for id in model?.tabs.flatMap(\.paneIDs) ?? [] {
            if let t = pool.terminals.removeValue(forKey: id) {
                panes[id] = t
                wire(t)
            }
            if let s = pool.screens.removeValue(forKey: id) {
                screens[id] = s
                wire(s)
            }
            if let r = pool.loginRetries.removeValue(forKey: id) { loginRetries[id] = r }
        }
    }

    // MARK: Drop targets

    /// The catcher over the pane area (pane zones) and the tab strip (an insertion slot).
    func installDropTargets(strip: Widget) {
        let drop = gtk_drop_target_new(gTypeString, paneDragActions)!
        onDropMotion(drop) { [unowned self] x, y in showDropPreview(x: x, y: y) }
        on(drop, "leave") { [unowned self] in showHighlight(nil) }
        onDrop(drop) { [unowned self] value, x, y in
            showHighlight(nil)
            guard let payload = DragPayload(value), let target = dropTarget(x: x, y: y, for: payload.item) else { return false }
            app.drop(payload.item, on: .pane(target))
            return true
        }
        gtk_widget_add_controller(catcher, cast(drop))
        // Clicks while picking a target (Move Pane…): the click drops it.
        let click = gtk_gesture_click_new()!
        onPressed(click) { [unowned self] _, x, y in
            guard let moving = app.pickingPane, let target = dropTarget(x: x, y: y, for: .pane(moving)) else { return }
            onMain { [weak self] in
                self?.app.endPicking()
                self?.app.drop(.pane(moving), on: .pane(target))
            }
        }
        gtk_widget_add_controller(catcher, cast(click))
        let motion = gtk_event_controller_motion_new()!
        onMotion(motion) { [unowned self] x, y in if app.pickingPane != nil { showDropPreview(x: x, y: y) } }
        gtk_widget_add_controller(catcher, cast(motion))

        // The strip: a gap opens where the tab (or the pane, as a new tab) will go.
        let stripDrop = gtk_drop_target_new(gTypeString, paneDragActions)!
        onDropMotion(stripDrop) { [unowned self] x, _ in showTabGap(at: tabSlot(stripX: x, strip: strip), for: app.dragged) }
        on(stripDrop, "leave") { [unowned self] in showTabGap(at: nil, for: nil) }
        onDrop(stripDrop) { [unowned self] value, x, _ in
            guard let payload = DragPayload(value), let model else { return false }
            let slot = tabSlot(stripX: x, strip: strip)
            showTabGap(at: nil, for: nil)
            app.drop(payload.item, on: .tabBar(window: model.id, slot: slot))
            return true
        }
        gtk_widget_add_controller(strip, cast(stripDrop))
        trackDragHover()
    }

    /// While something is dragged (or picked) anywhere in the app, the catcher takes the pointer.
    func setCatching(_ on: Bool) {
        gtk_widget_set_can_target(catcher, on ? 1 : 0)
        if !on { showHighlight(nil) }
    }

    /// The pane zone at (x, y) of the catcher; a tab is never offered a pane's centre (a swap is for panes).
    func dropTarget(x: Double, y: Double, for item: DragDrop.Item?) -> DropZones.Target? {
        guard let model else { return nil }
        let w = Double(gtk_widget_get_width(catcher)), h = Double(gtk_widget_get_height(catcher))
        guard w > 0, h > 0 else { return nil }
        let isTab: Bool = if case .tab? = item { true } else { false }
        return DropZones.target(x: x / w, y: y / h, frames: model.selectedTab.visibleFrames, center: !isTab)
    }

    private func showDropPreview(x: Double, y: Double) {
        let item = app.dragged
        guard let target = dropTarget(x: x, y: y, for: item), target.pane != app.draggedPane,
              !(item.map { isOwnTab($0, of: target.pane) } ?? false) else {
            showHighlight(nil)
            return
        }
        showHighlight(target.preview)
    }

    /// A tab dragged over one of its own panes: nothing to drop there.
    private func isOwnTab(_ item: DragDrop.Item, of pane: PaneID) -> Bool {
        guard case .tab(let id) = item else { return false }
        return model?.tabs.first { $0.id == id }?.root.contains(pane) ?? false
    }

    private func place(preview rect: UnitRect) { showHighlight(rect) }

    // MARK: Menus

    /// The pane's Move submenu (a second popover): new tab, new window, another tab, swap, zoom, duplicate.
    func paneMoveMenu(_ id: PaneID, on widget: Widget, x: Double, y: Double) {
        guard let model else { return }
        var items: [(String, @MainActor () -> Void)] = [
            ("Move Pane to New Tab", { [weak self] in self?.perform(.movePaneToNewTab) }),
            ("Move Pane to New Window", { [weak self] in self?.app.move(pane: id, to: .newWindow()) }),
            ("Move Pane… (pick a place)", { [weak self] in self?.app.startPicking(id, in: self) }),
        ]
        for (window, tab, name) in app.tabTargets() where !tab.root.contains(id) {
            items.append(("Move Pane to Tab › " + name, { [weak self] in
                self?.app.move(pane: id, to: .tabEdge(tab: tab.id, edge: .right))
            }))
            items.append(("Move Pane to Tab › " + name + " (below)", { [weak self] in
                self?.app.move(pane: id, to: .tabEdge(tab: tab.id, edge: .down))
            }))
            _ = window
        }
        for other in model.selectedTab.paneIDs where other != id {
            let name = panes[other]?.title ?? screens[other]?.title ?? "Pane"
            items.append(("Swap Pane with › " + name, { [weak self] in self?.app.swap(id, other) }))
        }
        items.append((model.selectedTab.zoomed == nil ? "Zoom Pane" : "Unzoom Pane", { [weak self] in
            self?.perform(.toggleZoom)
        }))
        items.append(("Duplicate Pane", { [weak self] in self?.perform(.duplicatePane) }))
        contextMenu(on: widget, x: x, y: y, items: items)
    }

    /// The tab's Move submenu: a new window, another window, another window's tab as a split, merge.
    func tabMoveMenu(_ tabID: UUID, on widget: Widget, x: Double, y: Double) {
        guard let model else { return }
        var items: [(String, @MainActor () -> Void)] = [
            ("Move Tab to New Window", { [weak self] in self?.app.move(tab: tabID, to: .newWindow()) }),
        ]
        for (window, title) in app.windowTargets() where window != model.id {
            items.append(("Move Tab to Window › " + title, { [weak self] in
                self?.app.move(tab: tabID, to: .window(window))
            }))
        }
        for (_, tab, name) in app.tabTargets() where tab.id != tabID {
            items.append(("Move Tab into Tab as Split › " + name, { [weak self] in
                self?.app.move(tab: tabID, to: .split(tab: tab.id, edge: .right))
            }))
        }
        if app.windows.count > 1 {
            items.append(("Merge All Windows", { [weak self] in
                guard let self else { return }
                app.perform(.mergeAllWindows, from: self)
            }))
        }
        contextMenu(on: widget, x: x, y: y, items: items)
    }

    func tabColorMenu(_ tabID: UUID, on widget: Widget, x: Double, y: Double) {
        let set: (TabColor?) -> Void = { [weak self] color in
            guard let self, let model, let i = model.tabIndex(of: tabID) else { return }
            var tabs = model.tabs
            tabs[i] = tabs[i].recolored(color)
            setModel(Window(id: model.id, tabs: tabs, selectedIndex: model.selectedIndex,
                            broadcastsInput: model.broadcastsInput, title: model.title))
        }
        contextMenu(on: widget, x: x, y: y, items: [("Default", { set(nil) })]
            + TabColor.allCases.map { color in (color.title, { set(color) }) })
    }

    func editWindowTitle() {
        guard let model else { return }
        let entry = gtk_entry_new()!
        gtk_editable_set_text(cast(entry), model.title ?? "")
        gtk_entry_set_placeholder_text(cast(entry), "Automatic title")
        gtk_entry_set_activates_default(cast(entry), 1)
        alert("Edit Window Title", "Leave it empty to show the selected tab's title.",
              responses: [Response(id: "cancel", label: "Cancel"), Response(id: "set", label: "Set", look: .suggested)],
              defaultID: "set", extra: entry, parent: window) { [weak self] id in
            guard id == "set", let self, let current = self.model else { return }
            setModel(current.retitled(entryText(entry)))
        }
        gtk_widget_grab_focus(entry)
    }

    // MARK: Pick a target (Move Pane…)

    /// The moved pane is outlined; arrows pick a target pane (its right half shows), Enter drops it on the right,
    /// Shift+Enter below, T makes it a tab, N a window, Escape cancels. A click on any pane, in any window, drops
    /// it on the edge under the pointer.
    func showPicking(_ id: PaneID?) {
        for (pid, t) in panes {
            if pid == id { gtk_widget_add_css_class(t.container, "move-source") } else {
                gtk_widget_remove_css_class(t.container, "move-source")
            }
        }
        picking = id.map { ($0, nil) }
        if id == nil { showHighlight(nil) }
    }

    func pickKey(keyval: UInt32, state: UInt32) -> Bool {
        guard let (moving, target) = picking, let model else { return false }
        let shift = state & GDK_SHIFT_MASK.rawValue != 0
        let tab = model.selectedTab
        func choose(_ direction: Direction) {
            let from = target ?? moving
            let next = tab.paneIDs.contains(from) ? tab.focusing(from).movingFocus(direction).focused : tab.focused
            picking = (moving, next == moving ? target : next)
            if let t = picking?.target, let rect = tab.visibleFrames[t] { place(preview: DropZones.half(of: rect, .right)) }
        }
        switch Int32(keyval) {
        case GDK_KEY_Escape: app.endPicking()
        case GDK_KEY_Left: choose(.left)
        case GDK_KEY_Right: choose(.right)
        case GDK_KEY_Up: choose(.up)
        case GDK_KEY_Down: choose(.down)
        case GDK_KEY_t, GDK_KEY_T:
            app.endPicking()
            app.move(pane: moving, to: .newTab(window: model.id))
        case GDK_KEY_n, GDK_KEY_N:
            app.endPicking()
            app.move(pane: moving, to: .newWindow())
        case GDK_KEY_Return, GDK_KEY_KP_Enter:
            guard let target else { return true }
            app.endPicking()
            app.move(pane: moving, to: .beside(pane: target, edge: shift ? .down : .right))
        default: break
        }
        return true
    }
}
