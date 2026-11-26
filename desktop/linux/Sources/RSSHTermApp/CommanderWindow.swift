// Files: the two-pane commander window (Midnight Commander keys plus Linux file-manager keys), the F3–F8 button
// bar, the transfers panel (progress, cancel, retry, conflicts), F4 remote edits (upload on save) and the host-key
// question of SFTP panes. Bound to CommanderModel / TransferQueueModel / RemoteEditSession.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

@MainActor
final class CommanderWindow: CommanderPrompts {
    let commander: CommanderModel
    private unowned let app: AppController
    private let places: FilePlaces
    private var window: Widget!
    private var left: FilePaneView!
    private var right: FilePaneView!
    private var transfersList: Widget!
    private var transfersRevealer: Widget!
    private var statusLabel: Widget!
    private var editsList: Widget!
    private var errorLabel: Widget!
    private var conflictShown: UUID?
    private var hostKeyShown: Set<ObjectIdentifier> = []
    private let keymap = CommanderKeymap.bindings(for: .linux)

    init(app: AppController, places: FilePlaces) {
        self.app = app
        self.places = places
        commander = CommanderModel(places: places)
        commander.openInEditor = { [unowned app] url in TextEditorLauncher.open(url, app: app) }
        commander.prompts = self

        window = cast(adw_window_new())
        gtk_window_set_title(cast(window), "Files")
        gtk_window_set_default_size(cast(window), 1100, 680)
        gtk_window_set_hide_on_close(cast(window), 1)

        left = FilePaneView(side: .left, commander: commander, window: self)
        right = FilePaneView(side: .right, commander: commander, window: self)
        let panes = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(cast(panes), left.widget)
        gtk_paned_set_end_child(cast(panes), right.widget)
        gtk_paned_set_position(cast(panes), 550)
        gtk_widget_set_vexpand(panes, 1)

        errorLabel = label("", css: ["error"], wrap: true)
        setMargins(errorLabel, 6)

        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        gtk_box_set_homogeneous(cast(buttons), 1)
        setMargins(buttons, 4)
        for entry in CommanderKeymap.buttonBar {
            let action = entry.action
            gtk_box_append(cast(buttons), button("\(entry.key) \(entry.title)", css: ["flat"]) { [unowned self] in
                run { [unowned self] in await commander.perform(action) }
            })
        }

        transfersList = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(transfersList), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(transfersList, "boxed-list")
        editsList = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(editsList), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(editsList, "boxed-list")
        let panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        setMargins(panel, 8)
        let panelHeader = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        let title = label("Transfers", css: ["heading"])
        gtk_widget_set_hexpand(title, 1)
        gtk_label_set_xalign(cast(title), 0)
        gtk_box_append(cast(panelHeader), title)
        gtk_box_append(cast(panelHeader), button("Clear Finished", css: ["flat"]) { [unowned self] in
            places.transfers.clearFinished()
        })
        gtk_box_append(cast(panel), panelHeader)
        gtk_box_append(cast(panel), transfersList)
        gtk_box_append(cast(panel), label("Edited Remotely (F4)", css: ["heading"]))
        gtk_box_append(cast(panel), editsList)
        let panelScroll = scrolled(panel)
        gtk_scrolled_window_set_min_content_height(cast(panelScroll), 160)
        transfersRevealer = gtk_revealer_new()
        gtk_revealer_set_child(cast(transfersRevealer), panelScroll)

        statusLabel = label("", css: ["dim-label", "caption"])
        gtk_label_set_xalign(cast(statusLabel), 0)
        setMargins(statusLabel, 4)

        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(cast(content), errorLabel)
        gtk_box_append(cast(content), panes)
        gtk_box_append(cast(content), buttons)
        gtk_box_append(cast(content), transfersRevealer)
        gtk_box_append(cast(content), statusLabel)

        let header = adw_header_bar_new()!
        let toggle = gtk_toggle_button_new()!
        gtk_button_set_icon_name(cast(toggle), "folder-download-symbolic")
        gtk_widget_set_tooltip_text(toggle, "Transfers")
        on(toggle, "toggled") { [unowned self] in
            gtk_revealer_set_reveal_child(cast(transfersRevealer), gtk_toggle_button_get_active(cast(toggle)))
        }
        adw_header_bar_pack_end(cast(header), toggle)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), header)
        adw_toolbar_view_set_content(cast(toolbar), content)
        adw_window_set_content(cast(window), toolbar)

        addKeyHandler(window) { [unowned self] keyval, state in handleKey(keyval: keyval, state: state) }
        observe({ [commander] in _ = commander.error; _ = commander.editSessions }) { [weak self] in self?.renderCommander() }
        observe({ [places] in _ = places.transfers.transfers; _ = places.transfers.pendingConflict }) { [weak self] in
            self?.renderTransfers()
        }
        for pane in [commander.left, commander.right] {
            observe({ _ = pane.hostKeyQuestion }) { [weak self] in self?.askHostKey(pane) }
        }
        run { [unowned self] in await commander.load() }
        renderCommander()
        renderTransfers()
    }

    var windowWidget: Widget { window }

    /// For the smoke test: each pane's place, folder and visible names, and the finished transfers.
    func snapshot() -> [String: Any] {
        func pane(_ m: FileBrowserModel) -> [String: Any] {
            ["place": m.placeTitle, "path": m.path.string, "items": m.visibleItems.map(\.name), "error": m.error ?? ""]
        }
        return ["left": pane(commander.left), "right": pane(commander.right),
                "active": commander.activeSide == .left ? "left" : "right",
                "completed": places.transfers.transfers.filter { $0.state == .completed }.count,
                "error": commander.error ?? ""]
    }

    func present() {
        gtk_window_present(cast(window))
        (commander.activeSide == .left ? left : right)?.focus()
    }

    // MARK: Keys

    private func handleKey(keyval: UInt32, state: UInt32) -> Bool {
        // Typing in an entry (filter, dialogs) is the entry's.
        if let focus = gtk_root_get_focus(cast(window)), isA(focus, gtk_text_get_type()) { return false }
        let mods = GdkModifiers(state: state)
        guard let chord = KeyTranslator.chord(keyval: keyval, modifiers: mods) else { return false }
        if chord.modifiers.isEmpty, chord.key == "up" || chord.key == "down" {
            commander.active.moveCursor(by: chord.key == "up" ? -1 : 1)
            return true
        }
        if chord.modifiers == [.shift], chord.key == "up" || chord.key == "down" {
            commander.active.moveCursor(by: chord.key == "up" ? -1 : 1, extend: true)
            return true
        }
        guard let action = keymap[chord] else { return false }
        run { [unowned self] in
            await commander.perform(action)
            if action == .switchPane { (commander.activeSide == .left ? left : right)?.focus() }
        }
        return true
    }

    // MARK: Rendering

    private func renderCommander() {
        gtk_label_set_text(cast(errorLabel), commander.error ?? "")
        gtk_widget_set_visible(errorLabel, commander.error == nil ? 0 : 1)
        while let child = gtk_widget_get_first_child(editsList) { gtk_list_box_remove(cast(editsList), child) }
        for session in commander.editSessions {
            let r = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(r), 0)
            adw_preferences_row_set_title(cast(r), "\(session.sourceName): \(session.remotePath.string)")
            adw_action_row_set_subtitle(cast(r), Self.describe(session.state, uploads: session.uploads))
            if session.state == .conflict {
                adw_action_row_add_suffix(cast(r), button("Upload Mine", css: ["flat"]) {
                    run { await session.resolveConflict(overwrite: true) }
                })
                adw_action_row_add_suffix(cast(r), button("Take Theirs", css: ["flat"]) {
                    run { await session.resolveConflict(overwrite: false) }
                })
            }
            adw_action_row_add_suffix(cast(r), button("Done", css: ["flat"]) { [unowned self] in
                run { [unowned self] in await commander.endEditing(session) }
            })
            gtk_list_box_append(cast(editsList), r)
            observe({ _ = session.state; _ = session.uploads }) { [weak self] in self?.renderCommander() }
        }
        if commander.editSessions.isEmpty {
            let r = adw_action_row_new()!
            adw_preferences_row_set_title(cast(r), "F4 opens a file in your editor; saving uploads it.")
            gtk_list_box_append(cast(editsList), r)
        }
    }

    static func describe(_ state: RemoteEditSession.State, uploads: Int) -> String {
        switch state {
        case .watching: uploads == 0 ? "Open in your editor; saving uploads it" : "Uploaded \(uploads)×, watching"
        case .uploading: "Uploading…"
        case .uploaded(let date): "Uploaded at \(FileRowText.date(date))"
        case .conflict: "The server's copy changed since you opened it"
        case .failed(let m): "Failed: \(m)"
        case .finished: "Done"
        }
    }

    private func renderTransfers() {
        let queue = places.transfers
        while let child = gtk_widget_get_first_child(transfersList) { gtk_list_box_remove(cast(transfersList), child) }
        for t in queue.transfers {
            let r = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(r), 0)
            adw_preferences_row_set_title(cast(r), t.title)
            let state: String = switch t.state {
            case .queued: "Waiting"
            case .running: t.currentName.map { "Copying \($0)" } ?? "Copying"
            case .completed: "Done"
            case .cancelled: "Cancelled"
            case .failed(let m): "Failed: \(m)"
            }
            adw_action_row_set_subtitle(cast(r), "\(state) · \(FileRowText.size(t.bytesDone, isDirectory: false)) of \(FileRowText.size(t.bytesTotal, isDirectory: false))")
            let bar = gtk_progress_bar_new()!
            gtk_progress_bar_set_fraction(cast(bar), t.fraction ?? (t.state == .completed ? 1 : 0))
            gtk_widget_set_valign(bar, GTK_ALIGN_CENTER)
            gtk_widget_set_size_request(bar, 120, -1)
            adw_action_row_add_suffix(cast(r), bar)
            let id = t.id
            if !t.state.isFinished {
                adw_action_row_add_suffix(cast(r), iconButton("process-stop-symbolic", tooltip: "Cancel") {
                    queue.cancel(id)
                })
            } else if case .failed = t.state {
                adw_action_row_add_suffix(cast(r), iconButton("view-refresh-symbolic", tooltip: "Retry") {
                    queue.retry(id)
                })
            }
            gtk_list_box_append(cast(transfersList), r)
        }
        if queue.transfers.isEmpty {
            let r = adw_action_row_new()!
            adw_preferences_row_set_title(cast(r), "No transfers. F5 copies, F6 moves to the other pane; drop files on a pane to upload.")
            gtk_list_box_append(cast(transfersList), r)
        }
        let active = queue.activeCount
        gtk_label_set_text(cast(statusLabel), active == 0 ? "No transfers running"
                           : "\(active) transfer(s) running" + (queue.overallFraction.map { " · \(Int($0 * 100)) %" } ?? ""))
        if active > 0 { gtk_revealer_set_reveal_child(cast(transfersRevealer), 1) }
        if let pending = queue.pendingConflict, conflictShown != pending.id {
            conflictShown = pending.id
            askConflict(pending.conflict)
        }
    }

    // MARK: Questions

    private func askConflict(_ conflict: TransferConflict) {
        let all = gtk_check_button_new_with_label("Apply to all")!
        let existing = conflict.existing
        alert("“\(conflict.destinationName)” Already Exists",
              "There: \(FileRowText.size(existing.size, isDirectory: existing.isDirectory)), \(FileRowText.date(existing.modified)).\n"
              + "New: \(FileRowText.size(conflict.source.size, isDirectory: conflict.source.isDirectory)), \(FileRowText.date(conflict.source.modified)).",
              responses: [Response(id: "cancel", label: "Stop"), Response(id: "skip", label: "Skip"),
                          Response(id: "rename", label: "Keep Both"), Response(id: "overwrite", label: "Replace", look: .destructive)],
              defaultID: "rename", extra: all, parent: window) { [unowned self] id in
            let applyToAll = gtk_check_button_get_active(cast(all)) != 0
            let action: ConflictAnswer.Action = switch id {
            case "overwrite": .overwrite
            case "skip": .skip
            case "rename": .rename
            default: .cancel
            }
            places.transfers.answer(ConflictAnswer(action, applyToAll: applyToAll))
        }
    }

    private func askHostKey(_ pane: FileBrowserModel) {
        guard let key = pane.hostKeyQuestion else { hostKeyShown.remove(ObjectIdentifier(pane)); return }
        guard hostKeyShown.insert(ObjectIdentifier(pane)).inserted else { return }
        alert("Trust \(key.host)?", "\(key.host):\(key.port) presents the \(key.keyType) key\n\(key.fingerprint)\n"
              + "Check it with the server's administrator before you trust it; it is pinned in the vault.",
              responses: [Response(id: "cancel", label: "Cancel"), Response(id: "trust", label: "Trust", look: .suggested)],
              parent: window) { [unowned self] id in
            hostKeyShown.remove(ObjectIdentifier(pane))
            run { await pane.answerHostKey(trust: id == "trust") }
        }
    }

    // MARK: CommanderPrompts

    func askName(title: String, initial: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var answered = false
            let entry = gtk_entry_new()!
            gtk_editable_set_text(cast(entry), initial)
            gtk_entry_set_activates_default(cast(entry), 1)
            alert(title, "", responses: [Response(id: "cancel", label: "Cancel"), Response(id: "ok", label: "OK", look: .suggested)],
                  defaultID: "ok", extra: entry, parent: window) { id in
                guard !answered else { return }
                answered = true
                let text = entryText(entry).trimmingCharacters(in: .whitespaces)
                cont.resume(returning: id == "ok" && !text.isEmpty ? text : nil)
            }
            gtk_widget_grab_focus(entry)
        }
    }

    func confirm(_ message: String, destructive: Bool) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var answered = false
            alert(message, "", responses: [Response(id: "cancel", label: "Cancel"),
                                           Response(id: "ok", label: destructive ? "Delete" : "OK", look: destructive ? .destructive : .suggested)],
                  parent: window) { id in
                guard !answered else { return }
                answered = true
                cont.resume(returning: id == "ok")
            }
        }
    }

    func view(_ item: FileItem, in pane: FileBrowserModel) {
        guard let source = pane.source else { return }
        run { [unowned self] in
            let text: String
            do {
                let data = try await source.readAll(item.path, limit: 2 * 1024 * 1024)
                text = String(data: data, encoding: .utf8) ?? "Not text (\(data.count) bytes)."
            } catch {
                text = "Could not read it: \(error.localizedDescription)"
            }
            let view = gtk_text_view_new()!
            gtk_text_view_set_editable(cast(view), 0)
            gtk_text_view_set_monospace(cast(view), 1)
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(cast(view)), text, -1)
            let dialog = makeDialog(title: item.name, width: 760, height: 560, content: scrolled(view))
            adw_dialog_present(cast(dialog), window)
        }
    }

    func editing(_ session: RemoteEditSession) {
        gtk_revealer_set_reveal_child(cast(transfersRevealer), 1)
        renderCommander()
    }
}
