// One commander pane: place picker, back/forward/up, path, filter, hidden toggle, sortable column headers, the rows
// (cursor = the selected row, marked items highlighted), status line. Files dropped from the desktop are copied
// here; rows drag to the other pane (Shift = move) and, for local files, out to the desktop.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

@MainActor
final class FilePaneView {
    let side: CommanderModel.Side
    let model: FileBrowserModel
    private unowned let commander: CommanderModel
    private unowned let window: CommanderWindow
    private(set) var widget: Widget!
    private(set) var list: Widget!
    private var placePicker: Widget!
    private var pathLabel: Widget!
    private var summary: Widget!
    private var errorLabel: Widget!
    private var spinner: Widget!
    private var rows: [FileItem] = []
    private var rendering = false
    private var places: [FilePlace] = []

    init(side: CommanderModel.Side, commander: CommanderModel, window: CommanderWindow) {
        self.side = side
        self.commander = commander
        self.window = window
        model = commander.pane(side)
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
        gtk_widget_add_css_class(widget, "file-pane")
        setMargins(widget, 4)

        let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        places = commander.places.places
        placePicker = gtk_drop_down_new(cast(stringList(places.map { commander.places.title(of: $0) })), nil)
        onNotify(placePicker, "selected") { [unowned self] in
            guard !rendering else { return }
            let i = Int(gtk_drop_down_get_selected(cast(placePicker)))
            guard places.indices.contains(i), places[i] != model.place else { return }
            run { [unowned self] in await model.switchTo(places[i]) }
        }
        gtk_box_append(cast(bar), placePicker)
        for (icon, tip, action) in [("go-previous-symbolic", "Back", { [unowned self] in run { await self.model.goBack() } }),
                                    ("go-next-symbolic", "Forward", { [unowned self] in run { await self.model.goForward() } }),
                                    ("go-up-symbolic", "Up (Backspace)", { [unowned self] in run { await self.model.goUp() } }),
                                    ("view-refresh-symbolic", "Refresh (Ctrl+R)", { [unowned self] in run { await self.model.refresh() } })]
            as [(String, String, VoidHandler)] {
            let b = iconButton(icon, tooltip: tip, action)
            gtk_widget_add_css_class(b, "flat")
            gtk_box_append(cast(bar), b)
        }
        spinner = gtk_spinner_new()
        gtk_box_append(cast(bar), spinner)
        let hidden = gtk_toggle_button_new()!
        gtk_button_set_icon_name(cast(hidden), "view-reveal-symbolic")
        gtk_widget_set_tooltip_text(hidden, "Hidden Files (Ctrl+H)")
        gtk_widget_add_css_class(hidden, "flat")
        on(hidden, "toggled") { [unowned self] in model.showHidden = gtk_toggle_button_get_active(cast(hidden)) != 0 }
        let filter = gtk_search_entry_new()!
        gtk_search_entry_set_placeholder_text(cast(filter), "Filter")
        gtk_search_entry_set_search_delay(cast(filter), 0)
        gtk_widget_set_hexpand(filter, 1)
        on(filter, "search-changed") { [unowned self] in model.query = entryText(filter) }
        gtk_box_append(cast(bar), filter)
        gtk_box_append(cast(bar), hidden)
        gtk_box_append(cast(widget), bar)

        pathLabel = label("", css: ["heading"])
        gtk_label_set_xalign(cast(pathLabel), 0)
        gtk_label_set_ellipsize(cast(pathLabel), PANGO_ELLIPSIZE_START)
        gtk_box_append(cast(widget), pathLabel)

        let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        for (title, key, width) in [("Name", FileBrowserModel.SortKey.name, Int32(-1)), ("Size", .size, 90), ("Modified", .date, 140)] {
            let b = button(title, css: ["flat", "caption-heading"]) { [unowned self] in model.sort(by: key) }
            if width < 0 { gtk_widget_set_hexpand(b, 1) } else { gtk_widget_set_size_request(b, width, -1) }
            gtk_widget_set_halign(gtk_button_get_child(cast(b)), width < 0 ? GTK_ALIGN_START : GTK_ALIGN_END)
            gtk_box_append(cast(header), b)
        }
        gtk_box_append(cast(widget), header)

        list = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_BROWSE)
        gtk_list_box_set_activate_on_single_click(cast(list), 0)
        gtk_widget_add_css_class(list, "file-list")
        gtk_box_append(cast(widget), scrolled(list))
        onPointer(list, "row-activated") { [unowned self] row in
            let i = Int(gtk_list_box_row_get_index(cast(row)))
            guard rows.indices.contains(i) else { return }
            run { [unowned self] in
                if let file = await model.activate(rows[i]) { window.view(file, in: model) }
            }
        }
        onPointer(list, "row-selected") { [unowned self] row in
            guard !rendering, let row else { return }
            let i = Int(gtk_list_box_row_get_index(cast(row)))
            if rows.indices.contains(i) { model.cursor = rows[i].path }
        }
        onFocusEnter(list) { [unowned self] in if commander.activeSide != side { commander.activeSide = side } }
        let click = gtk_gesture_click_new()
        onPressed(click) { [unowned self] _, _, _ in if commander.activeSide != side { commander.activeSide = side } }
        gtk_widget_add_controller(widget, cast(click))
        addDropTarget()

        errorLabel = label("", css: ["error", "caption"], wrap: true)
        gtk_box_append(cast(widget), errorLabel)
        summary = label("", css: ["dim-label", "caption"])
        gtk_label_set_xalign(cast(summary), 0)
        gtk_box_append(cast(widget), summary)

        observe({ [model, commander] in
            _ = model.visibleItems; _ = model.path; _ = model.isLoading; _ = model.error; _ = model.selection
            _ = model.place; _ = commander.activeSide
        }) { [weak self] in self?.render() }
        observe({ [model] in _ = model.cursor }) { [weak self] in self?.syncCursor() }
        render()
    }

    func focus() { gtk_widget_grab_focus(list) }

    private func render() {
        rendering = true
        defer { rendering = false }
        places = commander.places.places
        if let i = places.firstIndex(of: model.place) { gtk_drop_down_set_selected(cast(placePicker), guint(i)) }
        gtk_label_set_text(cast(pathLabel), "\(model.placeTitle): \(model.path.string)")
        model.isLoading ? gtk_spinner_start(cast(spinner)) : gtk_spinner_stop(cast(spinner))
        gtk_label_set_text(cast(errorLabel), model.error ?? "")
        gtk_widget_set_visible(errorLabel, model.error == nil ? 0 : 1)
        gtk_label_set_text(cast(summary), model.summary)
        if commander.activeSide == side { gtk_widget_add_css_class(widget, "active-pane") } else { gtk_widget_remove_css_class(widget, "active-pane") }

        rows = model.visibleItems
        while let child = gtk_widget_get_first_child(list) { gtk_list_box_remove(cast(list), child) }
        for item in rows {
            let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
            gtk_box_append(cast(box), gtk_image_new_from_icon_name(item.isDirectory ? "folder-symbolic" : "text-x-generic-symbolic"))
            let name = label(item.name)
            gtk_label_set_xalign(cast(name), 0)
            gtk_label_set_ellipsize(cast(name), PANGO_ELLIPSIZE_MIDDLE)
            gtk_widget_set_hexpand(name, 1)
            gtk_box_append(cast(box), name)
            let size = label(FileRowText.size(item.size, isDirectory: item.isDirectory), css: ["dim-label", "numeric"])
            gtk_widget_set_size_request(size, 90, -1)
            gtk_label_set_xalign(cast(size), 1)
            gtk_box_append(cast(box), size)
            let date = label(FileRowText.date(item.modified), css: ["dim-label", "numeric"])
            gtk_widget_set_size_request(date, 140, -1)
            gtk_label_set_xalign(cast(date), 1)
            gtk_box_append(cast(box), date)
            gtk_widget_set_tooltip_text(box, FileRowText.mode(item.permissions, isDirectory: item.isDirectory))
            let row = gtk_list_box_row_new()!
            gtk_list_box_row_set_child(cast(row), box)
            if model.selection.contains(item.path) { gtk_widget_add_css_class(row, "marked") }
            addDragSource(row, item: item)
            gtk_list_box_append(cast(list), row)
        }
        syncCursor()
    }

    private func syncCursor() {
        guard let cursor = model.cursor, let i = rows.firstIndex(where: { $0.path == cursor }),
              let row = gtk_list_box_get_row_at_index(cast(list), Int32(i)) else { return }
        rendering = true
        gtk_list_box_select_row(cast(list), row)
        rendering = false
    }

    // MARK: Drag and drop

    private var isLocal: Bool { model.place == .local }

    private func addDragSource(_ row: Widget, item: FileItem) {
        let drag = gtk_drag_source_new()!
        gtk_drag_source_set_actions(drag, GdkDragAction(rawValue: GDK_ACTION_COPY.rawValue | GDK_ACTION_MOVE.rawValue))
        onDragPrepare(drag) { [unowned self] _, _ in
            let items = model.selection.contains(item.path) ? model.selectedItems : [item]
            let token = textContent(PaneDragToken.encode(side: side, paths: items.map(\.path)))
            guard isLocal else { return token }
            // Local files also go to the desktop's file manager as a URI list.
            let bytes = Array(PaneDragToken.uriList(items.map(\.path)).utf8)
            let gbytes = bytes.withUnsafeBufferPointer { g_bytes_new($0.baseAddress, gsize($0.count)) }
            defer { g_bytes_unref(gbytes) }
            let uris = gdk_content_provider_new_for_bytes("text/uri-list", gbytes)
            var providers: [UnsafeMutablePointer<GdkContentProvider>?] = [cast(uris), cast(token)]
            let union = providers.withUnsafeMutableBufferPointer { buffer in
                gdk_content_provider_new_union(buffer.baseAddress, 2)
            }
            return cast(union)
        }
        gtk_widget_add_controller(row, cast(drag))
    }

    private func addDropTarget() {
        let target = gtk_drop_target_new(GType(0), GdkDragAction(rawValue: GDK_ACTION_COPY.rawValue | GDK_ACTION_MOVE.rawValue))!
        var types: [GType] = [gTypeString, gdk_file_list_get_type()]
        gtk_drop_target_set_gtypes(target, &types, 2)
        onDrop(target) { [unowned self] value, _, _ in
            guard let value else { return false }
            let shift = gtk_event_controller_get_current_event_state(cast(target)).rawValue & GDK_SHIFT_MASK.rawValue != 0
            if value.pointee.g_type == gdk_file_list_get_type() {
                let files = gdk_file_list_get_files(OpaquePointer(g_value_get_boxed(value)))
                var urls: [URL] = []
                var node = files
                while let n = node {
                    if let path = g_file_get_path(OpaquePointer(n.pointee.data)) {
                        urls.append(URL(fileURLWithPath: String(cString: path)))
                        g_free(path)
                    }
                    node = n.pointee.next
                }
                g_slist_free(files)
                run { [unowned self] in _ = await commander.dropLocalFiles(urls, onto: side) }
                return !urls.isEmpty
            }
            guard let raw = g_value_get_string(value), let token = PaneDragToken.decode(String(cString: raw)),
                  token.side != side else { return false }
            let from = commander.pane(token.side)
            let items = from.items.filter { token.paths.contains($0.path) }
            run { [unowned self] in _ = await commander.dropFromPane(items, from: token.side, operation: shift ? .move : .copy) }
            return true
        }
        gtk_widget_add_controller(list, cast(target))
    }
}
