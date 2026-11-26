// The server sidebar: search, tag chips, folders ("Servers" first), servers. Enter / double-click connects (a tab
// running `ssh <alias>`), right-click has Connect, Split, Edit, Duplicate, Files, Move, Delete; servers drag onto a
// folder header (move) or onto another server of the same folder (reorder). Bound to ServerListModel.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

@MainActor
final class ServerSidebar {
    private(set) var widget: Widget!
    private var list: Widget!
    private var search: Widget!
    private var tags: Widget!
    private var errorLabel: Widget!
    private var rows: [SidebarRows.Row] = []
    private let model: ServerListModel
    private unowned let window: MainWindow
    private var syncingSelection = false

    init(model: ServerListModel, window: MainWindow) {
        self.model = model
        self.window = window
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
        gtk_widget_set_size_request(widget, 260, -1)
        gtk_widget_add_css_class(widget, "server-sidebar")

        search = gtk_search_entry_new()
        gtk_search_entry_set_placeholder_text(cast(search), "Search servers, tags, notes")
        gtk_search_entry_set_search_delay(cast(search), 0)
        setMargins(search, 6)
        gtk_widget_set_margin_bottom(search, 0)
        gtk_box_append(cast(widget), search)

        tags = gtk_flow_box_new()
        gtk_flow_box_set_selection_mode(cast(tags), GTK_SELECTION_NONE)
        gtk_flow_box_set_max_children_per_line(cast(tags), 6)
        gtk_widget_set_margin_start(tags, 6)
        gtk_widget_set_margin_end(tags, 6)
        gtk_box_append(cast(widget), tags)

        let tools = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)!
        gtk_widget_set_margin_start(tools, 6)
        gtk_widget_set_margin_end(tools, 6)
        let actions: [(String, String, VoidHandler)] = [
            ("list-add-symbolic", "New Server", { [unowned self] in newServer(inGroup: nil) }),
            ("folder-new-symbolic", "New Folder", { [unowned self] in newFolder() }),
            ("video-display-symbolic", "New Remote Desktop", { [unowned window] in window.newRemoteDesktop(inGroup: nil) }),
            ("network-workgroup-symbolic", "Scan Network…", { [unowned window] in window.app.showNetworkScan() }),
            ("document-open-symbolic", "Import ~/.ssh/config…", { [unowned window] in window.app.showSSHConfigImport() }),
            ("go-jump-symbolic", "Quick Connect…", { [unowned window] in window.app.showQuickConnect(over: window) }),
            ("folder-remote-symbolic", "File Manager", { [unowned window] in window.app.showCommander() }),
        ]
        for (icon, tip, action) in actions {
            let b = iconButton(icon, tooltip: tip, action)
            gtk_widget_add_css_class(b, "flat")
            gtk_box_append(cast(tools), b)
        }
        gtk_box_append(cast(widget), tools)

        list = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_MULTIPLE)
        gtk_list_box_set_activate_on_single_click(cast(list), 0)
        gtk_widget_add_css_class(list, "navigation-sidebar")
        gtk_box_append(cast(widget), scrolled(list))

        errorLabel = label("", css: ["error", "caption"], wrap: true)
        setMargins(errorLabel, 6)
        gtk_widget_set_visible(errorLabel, 0)
        gtk_box_append(cast(widget), errorLabel)

        on(search, "search-changed") { [unowned self] in model.query = entryText(search) }
        onPointer(list, "row-activated") { [unowned self] row in activated(Int(gtk_list_box_row_get_index(cast(row))), split: false) }
        on(list, "selected-rows-changed") { [unowned self] in selectionChanged() }
        onRightClick(list) { [unowned self] x, y in rightClick(x: x, y: y) }
        addKeyHandler(list, capture: false) { [unowned self] keyval, state in
            switch keyval {
            case 0xffff: deleteSelected(); return true // Delete
            case 0xff0d, 0xff8d: // Shift+Enter: split (plain Enter is row-activated)
                guard state & 1 != 0, let i = focusedIndex() else { return false }
                activated(i, split: true)
                return true
            default: return false
            }
        }
        observe({ [model] in _ = model.sections; _ = model.allTags; _ = model.tagFilter; _ = model.error; _ = model.vault.remoteDesktops }) { [weak self] in
            self?.reload()
        }
        reload()
    }

    // MARK: Rendering

    private func reload() {
        rows = SidebarRows.flatten(model.sections, desktops: model.vault.remoteDesktops, query: model.query)
        syncingSelection = true
        defer { syncingSelection = false }
        while let child = gtk_widget_get_first_child(list) { gtk_list_box_remove(cast(list), child) }
        for (index, row) in rows.enumerated() {
            switch row {
            case .header(let groupID, let title, let count, let collapsed):
                let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
                let arrow = gtk_image_new_from_icon_name(collapsed ? "pan-end-symbolic" : "pan-down-symbolic")!
                gtk_box_append(cast(box), arrow)
                let l = label(title, css: ["heading"])
                gtk_widget_set_hexpand(l, 1)
                gtk_label_set_xalign(cast(l), 0)
                gtk_box_append(cast(box), l)
                gtk_box_append(cast(box), label("\(count)", css: ["dim-label", "caption"]))
                setMargins(box, 4)
                let r = gtk_list_box_row_new()!
                gtk_list_box_row_set_child(cast(r), box)
                gtk_list_box_row_set_selectable(cast(r), 0)
                let click = gtk_gesture_click_new()
                onPressed(click) { [unowned self] _, _, _ in model.toggleCollapsed(groupID) }
                gtk_widget_add_controller(r, cast(click))
                addDropTarget(r, groupID: groupID, beforeIndex: nil)
                gtk_list_box_append(cast(list), r)
            case .server(let server, let groupID):
                let r = adw_action_row_new()!
                adw_preferences_row_set_use_markup(cast(r), 0)
                adw_preferences_row_set_title(cast(r), server.name.isEmpty ? server.host : server.name)
                adw_action_row_set_subtitle(cast(r), SidebarRows.subtitle(server, screens: model.vault.services(of: server.id).map { ScreenService($0.kind) }))
                adw_action_row_add_prefix(cast(r), gtk_image_new_from_icon_name("network-server-symbolic"))
                if !server.jumpHosts.isEmpty {
                    adw_action_row_add_suffix(cast(r), label("via \(server.jumpHosts.count)", css: ["dim-label", "caption"]))
                }
                gtk_widget_set_tooltip_text(r, server.notes)
                let drag = gtk_drag_source_new()!
                gtk_drag_source_set_actions(drag, GDK_ACTION_MOVE)
                let id = server.id
                onDragPrepare(drag) { _, _ in textContent(id.uuidString) }
                gtk_widget_add_controller(r, cast(drag))
                addDropTarget(r, groupID: groupID, beforeIndex: index)
                gtk_list_box_append(cast(list), r)
                if model.selection.contains(server.id) { gtk_list_box_select_row(cast(list), cast(r)) }
            case .desktop(let desktop, _):
                let r = adw_action_row_new()!
                adw_preferences_row_set_use_markup(cast(r), 0)
                adw_preferences_row_set_title(cast(r), desktop.name)
                adw_action_row_set_subtitle(cast(r), SidebarRows.subtitle(desktop, servers: model.vault.servers))
                adw_action_row_add_prefix(cast(r), gtk_image_new_from_icon_name("video-display-symbolic"))
                gtk_list_box_append(cast(list), r)
            }
        }
        rebuildTags()
        gtk_label_set_text(cast(errorLabel), model.error ?? "")
        gtk_widget_set_visible(errorLabel, model.error == nil ? 0 : 1)
    }

    private func rebuildTags() {
        while let child = gtk_widget_get_first_child(tags) { gtk_flow_box_remove(cast(tags), child) }
        for tag in model.allTags {
            let b = gtk_toggle_button_new_with_label("#\(tag)")!
            gtk_widget_add_css_class(b, "pill")
            gtk_widget_add_css_class(b, "small")
            gtk_toggle_button_set_active(cast(b), model.tagFilter == tag ? 1 : 0)
            on(b, "toggled") { [unowned self] in
                let on = gtk_toggle_button_get_active(cast(b)) != 0
                onMain { [unowned self] in model.tagFilter = on ? tag : nil }
            }
            gtk_flow_box_append(cast(tags), b)
        }
        gtk_widget_set_visible(tags, model.allTags.isEmpty ? 0 : 1)
    }

    /// Drops: a server id onto a folder header (move there) or onto a server row (move into its folder, before it).
    private func addDropTarget(_ row: Widget, groupID: UUID?, beforeIndex: Int?) {
        let target = gtk_drop_target_new(gTypeString, GDK_ACTION_MOVE)!
        onDrop(target) { [unowned self] value, _, _ in
            guard let value, let raw = g_value_get_string(value), let id = UUID(uuidString: String(cString: raw)) else { return false }
            run { [unowned self] in await drop(id, groupID: groupID, beforeIndex: beforeIndex) }
            return true
        }
        gtk_widget_add_controller(row, cast(target))
    }

    private func drop(_ id: UUID, groupID: UUID?, beforeIndex: Int?) async {
        let section = model.sections.first { $0.groupID == groupID }
        let from = section?.servers.firstIndex { $0.id == id }
        if let from, let beforeIndex, case .server(let target, _) = rows[beforeIndex],
           let to = section?.servers.firstIndex(where: { $0.id == target.id }) {
            await model.reorder(inGroup: groupID, fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        } else if from == nil {
            _ = await model.move([id], toGroup: groupID)
        }
    }

    // MARK: Actions

    private func server(at index: Int) -> Server? {
        guard rows.indices.contains(index), case .server(let s, _) = rows[index] else { return nil }
        return s
    }

    private func focusedIndex() -> Int? {
        guard let focus = gtk_root_get_focus(gtk_widget_get_root(list)),
              let row = gtk_widget_get_ancestor(focus, gtk_list_box_row_get_type()) else { return nil }
        return Int(gtk_list_box_row_get_index(cast(row)))
    }

    private func activated(_ index: Int, split: Bool) {
        if rows.indices.contains(index), case .desktop(let d, _) = rows[index] {
            return window.openRemoteDesktop(d.id, split: split)
        }
        guard let s = server(at: index) else { return }
        window.openServer(s.id, split: split)
    }

    private func selectionChanged() {
        guard !syncingSelection else { return }
        var ids = Set<UUID>()
        var node = gtk_widget_get_first_child(list)
        while let row = node {
            if isA(row, gtk_list_box_row_get_type()), gtk_list_box_row_is_selected(cast(row)) != 0,
               let s = server(at: Int(gtk_list_box_row_get_index(cast(row)))) { ids.insert(s.id) }
            node = gtk_widget_get_next_sibling(row)
        }
        model.selection = ids
    }

    private func rightClick(x: Double, y: Double) {
        guard let row = gtk_list_box_get_row_at_y(cast(list), Int32(y)) else {
            return contextMenu(on: list, x: x, y: y, items: [("New Server…", { [unowned self] in newServer(inGroup: nil) }),
                                                            ("New Remote Desktop…", { [unowned self] in window.newRemoteDesktop(inGroup: nil) }),
                                                            ("New Folder…", { [unowned self] in newFolder() })])
        }
        let index = Int(gtk_list_box_row_get_index(row))
        switch rows[index] {
        case .header(let groupID, let title, _, _):
            var items: [(String, @MainActor () -> Void)] = [("New Server Here…", { [unowned self] in newServer(inGroup: groupID) }),
                                                 ("New Remote Desktop Here…", { [unowned self] in window.newRemoteDesktop(inGroup: groupID) })]
            if let groupID {
                items.append(("Rename Folder…", { [unowned self] in renameFolder(groupID, title) }))
                items.append(("Delete Folder", { [unowned self] in run { [unowned self] in _ = await model.deleteGroup(groupID) } }))
            }
            contextMenu(on: list, x: x, y: y, items: items)
        case .server(let s, _):
            if !model.selection.contains(s.id) {
                gtk_list_box_unselect_all(cast(list))
                gtk_list_box_select_row(cast(list), row)
            }
            var items: [(String, () -> Void)] = s.sshEnabled ? [
                ("Connect", { [unowned self] in window.openServer(s.id, split: false) }),
                ("Connect in Split", { [unowned self] in window.openServer(s.id, split: true) }),
            ] : []
            for screen in model.vault.services(of: s.id) {
                let title = ScreenService(screen.kind) == .rdp ? "Remote Desktop (RDP)" : screen.kind.title
                items.append(("Open \(title)", { [unowned self] in window.openRemoteDesktop(screen.id, split: false) }))
                items.append(("Open \(title) in Split", { [unowned self] in window.openRemoteDesktop(screen.id, split: true) }))
                items.append(("Edit \(ScreenService(screen.kind).shortTitle) Settings…", { [unowned self] in window.editRemoteDesktop(screen.id) }))
            }
            items += [
                ("Edit…", { [unowned self] in edit(s.id) }),
                ("Duplicate", { [unowned self] in run { [unowned self] in _ = await model.duplicate(s.id) } }),
                ("Browse Files", { [unowned self] in window.app.showCommander(at: OpenHere.Target(place: .server(s.id), path: nil)) }),
                ("Move to Servers", { [unowned self] in run { [unowned self] in _ = await model.move(Array(model.selection), toGroup: nil) } }),
            ]
            for group in model.vault.groups {
                items.append(("Move to \(group.name)", { [unowned self] in
                    run { [unowned self] in _ = await model.move(Array(model.selection), toGroup: group.id) }
                }))
            }
            items.append(("Delete…", { [unowned self] in deleteSelected() }))
            contextMenu(on: list, x: x, y: y, items: items)
        case .desktop(let d, _):
            var items: [(String, @MainActor () -> Void)] = [
                ("Connect", { [unowned self] in window.openRemoteDesktop(d.id, split: false) }),
                ("Connect in Split", { [unowned self] in window.openRemoteDesktop(d.id, split: true) }),
                ("Edit…", { [unowned self] in window.editRemoteDesktop(d.id) }),
            ]
            if let match = model.vault.mergeSuggestions.first(where: { $0.desktop.id == d.id }) {
                items.append(("Add to \(match.server.name)…", { [unowned self] in askMerge(d, into: match.server) }))
            }
            items.append(("Delete…", { [unowned self] in deleteDesktop(d) }))
            contextMenu(on: list, x: x, y: y, items: items)
        }
    }

    func newServer(inGroup groupID: UUID?) {
        ServerEditorDialog(model: model.editorForNewServer(inGroup: groupID), app: window.app, parent: window.window).present()
    }

    func edit(_ id: UUID) {
        guard let editor = model.editor(for: id) else { return }
        ServerEditorDialog(model: editor, app: window.app, parent: window.window).present()
    }

    /// Never merged unasked: "Add <screen> to <server>" or "Keep as a Separate Server" (no more suggestions).
    private func askMerge(_ d: RemoteDesktop, into server: Server) {
        let folder = server.groupID.flatMap { id in model.vault.groups.first { $0.id == id }?.name } ?? ServerListModel.ungroupedTitle
        alert("Add \(d.name) to \(server.name)?",
              "\(server.name) (in \(folder)) has the same host. Added, the screen opens from that server's menu and follows its name and folder.",
              responses: [Response(id: "cancel", label: "Cancel"), Response(id: "keep", label: "Keep as a Separate Server"),
                          Response(id: "merge", label: "Add to \(server.name)", look: .suggested)],
              parent: window.window) { [unowned self] id in
            guard id != "cancel", let document = window.app.document else { return }
            do {
                let next = id == "merge" ? try document.vault.mergingRemoteDesktop(d.id, into: server.id)
                    : try document.vault.keepingSeparate(d.id)
                run { try? await document.commit(next) }
            } catch {
                message("Not Changed", error.localizedDescription, parent: window.window)
            }
        }
    }

    private func deleteDesktop(_ d: RemoteDesktop) {
        alert("Delete \(d.name)?", "Its password stays in Keys and Passwords.",
              responses: [Response(id: "cancel", label: "Cancel"), Response(id: "delete", label: "Delete", look: .destructive)],
              parent: window.window) { [unowned self] id in
            guard id == "delete", let document = window.app.document,
                  let next = try? document.vault.deletingRemoteDesktops([d.id]) else { return }
            run { try? await document.commit(next) }
        }
    }

    private func newFolder() {
        askText("New Folder", "Name of the folder.", initial: "", action: "Create", parent: window.window) { [unowned self] name in
            run { [unowned self] in _ = await model.addGroup(named: name) }
        }
    }

    private func renameFolder(_ id: UUID, _ title: String) {
        askText("Rename Folder", "", initial: title, action: "Rename", parent: window.window) { [unowned self] name in
            run { [unowned self] in _ = await model.renameGroup(id, to: name) }
        }
    }

    private func deleteSelected() {
        let servers = model.selectedServers
        guard !servers.isEmpty else { return }
        let names = servers.map(\.name).prefix(5).joined(separator: ", ")
        alert(servers.count == 1 ? "Delete \(names)?" : "Delete \(servers.count) Servers?",
              servers.count == 1 ? "Its keys and passwords stay in Keys & Passwords." : "\(names)\(servers.count > 5 ? ", …" : ""). Keys and passwords stay.",
              responses: [Response(id: "cancel", label: "Cancel"), Response(id: "delete", label: "Delete", look: .destructive)],
              parent: window.window) { [unowned self] id in
            guard id == "delete" else { return }
            run { [unowned self] in _ = await model.delete(Set(servers.map(\.id))) }
        }
    }
}

/// A one-line text question; `submit` gets the trimmed text (never on cancel or when empty).
func askText(_ heading: String, _ body: String, initial: String, action: String, parent: Widget,
             submit: @escaping (String) -> Void) {
    let entry = gtk_entry_new()!
    gtk_editable_set_text(cast(entry), initial)
    gtk_entry_set_activates_default(cast(entry), 1)
    alert(heading, body, responses: [Response(id: "cancel", label: "Cancel"), Response(id: "ok", label: action, look: .suggested)],
          defaultID: "ok", extra: entry, parent: parent) { id in
        let text = entryText(entry).trimmingCharacters(in: .whitespaces)
        if id == "ok", !text.isEmpty { submit(text) }
    }
    gtk_widget_grab_focus(entry)
}
