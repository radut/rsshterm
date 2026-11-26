// New / edit server: name, host, port, user, folder, login (saved password or key, or a new password), Jump
// Through (saved servers or user@host:port), agent forwarding, rSshD session mode, per-server theme and font, tags
// and notes. Bound to ServerEditorModel; Save validates there, messages appear under the groups.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit

@MainActor
final class ServerEditorDialog {
    private let model: ServerEditorModel
    private unowned let app: AppController
    private let parent: Widget
    private var dialog: Widget!
    private var serverGroup: Widget!
    private var loginGroup: Widget!
    private var jumpGroup: Widget!
    private var servicesGroup: Widget!
    private var jumpList: Widget!
    private var newPasswordRow: Widget!
    private var errorLabel: Widget!
    private var saveButton: Widget!
    private var keepAlive: ServerEditorDialog?

    init(model: ServerEditorModel, app: AppController, parent: Widget) {
        self.model = model
        self.app = app
        self.parent = parent
        let page = adw_preferences_page_new()!

        // Server
        serverGroup = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(serverGroup), "Server")
        adw_preferences_page_add(cast(page), cast(serverGroup))
        let rows: [(String, String, (String) -> Void)] = [
            ("Name", model.draft.name, { model.draft.name = $0 }),
            ("Host", model.draft.host, { model.draft.host = $0 }),
            ("Port", model.draft.port, { model.draft.port = $0 }),
            ("User", model.draft.username, { model.draft.username = $0 }),
        ]
        for (title, text, changed) in rows { adw_preferences_group_add(cast(serverGroup), entryRow(title, text: text, changed: changed)) }
        let groups = model.groups
        adw_preferences_group_add(cast(serverGroup), comboRow("Folder", titles: [ServerListModel.ungroupedTitle] + groups.map(\.name),
                                                               selected: (groups.firstIndex { $0.id == model.draft.groupID } ?? -1) + 1) { i in
            model.draft.groupID = i == 0 ? nil : groups[i - 1].id
        })

        // Services: SSH by default; RDP and VNC open the same machine as a screen (their settings: Edit … Settings).
        servicesGroup = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(servicesGroup), "Open As")
        adw_preferences_page_add(cast(page), cast(servicesGroup))
        let sshRow = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(sshRow), "SSH")
        adw_switch_row_set_active(cast(sshRow), model.draft.sshEnabled ? 1 : 0)
        onNotify(sshRow, "active") { model.draft.sshEnabled = adw_switch_row_get_active(cast(sshRow)) != 0 }
        adw_preferences_group_add(cast(servicesGroup), sshRow)
        for service in ScreenService.allCases {
            let row = adw_switch_row_new()!
            adw_preferences_row_set_title(cast(row), service.title)
            adw_action_row_set_subtitle(cast(row), service == .rdp ? "Port 3389, through this server's SSH when SSH is on"
                                                                     : "Port 5900, through this server's SSH when SSH is on")
            adw_switch_row_set_active(cast(row), model.screens.contains(service) ? 1 : 0)
            onNotify(row, "active") {
                if adw_switch_row_get_active(cast(row)) != 0 { model.screens.insert(service) } else { model.screens.remove(service) }
            }
            adw_preferences_group_add(cast(servicesGroup), row)
        }

        // Login
        loginGroup = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(loginGroup), "Login")
        adw_preferences_page_add(cast(page), cast(loginGroup))
        let passwords = model.passwords, keys = model.keys
        let logins: [ServerEditorModel.Login] = [.none] + passwords.map { .saved($0.id) } + keys.map { .saved($0.id) } + [.newPassword]
        let titles = ["None (agent keys, or ask)"] + passwords.map { "Password: \($0.label)" } + keys.map { "Key: \($0.label)" }
            + ["New Password…"]
        newPasswordRow = adw_password_entry_row_new()
        adw_preferences_row_set_title(cast(newPasswordRow), "New Password")
        let pwRow: Widget = newPasswordRow
        on(pwRow, "changed") { model.newPassword = string(gtk_editable_get_text(cast(pwRow))) }
        adw_preferences_group_add(cast(loginGroup), comboRow("Log In With", titles: titles,
                                                              selected: logins.firstIndex(of: model.login) ?? 0) { [unowned self] i in
            model.login = logins[i]
            gtk_widget_set_visible(newPasswordRow, model.login == .newPassword ? 1 : 0)
        })
        adw_preferences_group_add(cast(loginGroup), newPasswordRow)
        gtk_widget_set_visible(newPasswordRow, model.login == .newPassword ? 1 : 0)

        // Jump through
        jumpGroup = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(jumpGroup), "Jump Through")
        adw_preferences_group_set_description(cast(jumpGroup), "Hosts ssh goes through first, in order (ProxyJump).")
        adw_preferences_page_add(cast(page), cast(jumpGroup))
        jumpList = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(jumpList), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(jumpList, "boxed-list")
        adw_preferences_group_add(cast(jumpGroup), jumpList)
        let candidates = model.jumpCandidates
        let addBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        gtk_widget_set_margin_top(addBox, 6)
        let serverPick = gtk_drop_down_new(cast(stringList(["Saved server…"] + candidates.map(\.name))), nil)!
        onNotify(serverPick, "selected") { [unowned self] in
            let i = Int(gtk_drop_down_get_selected(cast(serverPick)))
            guard i > 0 else { return }
            model.addJump(server: candidates[i - 1].id)
            gtk_drop_down_set_selected(cast(serverPick), 0)
            renderJumps()
        }
        let addressEntry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(cast(addressEntry), "or user@host:port")
        gtk_widget_set_hexpand(addressEntry, 1)
        let addAddress = { [unowned self] in
            if model.addJump(address: entryText(addressEntry)) {
                gtk_editable_set_text(cast(addressEntry), "")
                renderJumps()
            } else {
                gtk_widget_add_css_class(addressEntry, "error")
            }
        }
        on(addressEntry, "activate", addAddress)
        gtk_box_append(cast(addBox), serverPick)
        gtk_box_append(cast(addBox), addressEntry)
        gtk_box_append(cast(addBox), button("Add", addAddress))
        adw_preferences_group_add(cast(jumpGroup), addBox)

        // Session
        let session = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(session), "Session")
        adw_preferences_page_add(cast(page), cast(session))
        let switches = AgentSwitch.allCases
        adw_preferences_group_add(cast(session), comboRow("Forward Agent", titles: switches.map { $0 == .default ? "Default" : $0.rawValue.capitalized },
                                                           selected: switches.firstIndex(of: model.forwardAgent) ?? 0) { i in
            model.forwardAgent = switches[i]
        })
        let backends = model.sessionBackends
        adw_preferences_group_add(cast(session), comboRow("rSshD Sessions", titles: ["Default"] + backends.map(\.title),
                                                           selected: (backends.firstIndex { $0 == model.draft.sessionDaemon } ?? -1) + 1) { i in
            model.draft.sessionDaemon = i == 0 ? nil : backends[i - 1]
        })

        // Appearance
        let look = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(look), "Appearance")
        adw_preferences_group_set_description(cast(look), "Overrides Preferences for this server's tabs.")
        adw_preferences_page_add(cast(page), cast(look))
        let themes = model.themes
        adw_preferences_group_add(cast(look), comboRow("Theme", titles: ["Default"] + themes.map(\.name),
                                                        selected: (themes.firstIndex { $0.id == model.draft.themeID } ?? -1) + 1) { i in
            model.draft.themeID = i == 0 ? nil : themes[i - 1].id
        })
        let fonts = model.fonts
        adw_preferences_group_add(cast(look), comboRow("Font", titles: ["Default"] + fonts.map(\.name),
                                                        selected: (fonts.firstIndex { $0.name == model.draft.fontFamily } ?? -1) + 1) { i in
            model.draft.fontFamily = i == 0 ? nil : fonts[i - 1].name
        })
        let sizes = Array(model.fontSizes)
        adw_preferences_group_add(cast(look), comboRow("Font Size", titles: ["Default"] + sizes.map { "\($0) pt" },
                                                        selected: (sizes.firstIndex { $0 == model.draft.fontSize } ?? -1) + 1) { i in
            model.draft.fontSize = i == 0 ? nil : sizes[i - 1]
        })

        // Tags & notes
        let more = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(more), "Tags and Notes")
        adw_preferences_page_add(cast(page), cast(more))
        adw_preferences_group_add(cast(more), entryRow("Tags (comma-separated)", text: model.tagsText) { model.tagsText = $0 })
        let notes = gtk_text_view_new()!
        gtk_text_view_set_wrap_mode(cast(notes), GTK_WRAP_WORD_CHAR)
        gtk_widget_set_size_request(notes, -1, 90)
        setMargins(notes, 8)
        let buffer = gtk_text_view_get_buffer(cast(notes))
        gtk_text_buffer_set_text(buffer, model.draft.notes ?? "", -1)
        on(buffer, "changed") {
            var start = GtkTextIter(), end = GtkTextIter()
            gtk_text_buffer_get_bounds(buffer, &start, &end)
            let text = gtk_text_buffer_get_text(buffer, &start, &end, 0).map { p -> String in defer { g_free(p) }; return String(cString: p) } ?? ""
            model.draft.notes = text.isEmpty ? nil : text
        }
        let frame = gtk_frame_new(nil)!
        gtk_frame_set_child(cast(frame), notes)
        adw_preferences_group_add(cast(more), frame)

        errorLabel = label("", css: ["error"], wrap: true)
        setMargins(errorLabel, 12)
        gtk_widget_set_visible(errorLabel, 0)
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(cast(content), errorLabel)
        gtk_box_append(cast(content), page)
        gtk_widget_set_vexpand(page, 1)

        saveButton = button("Save", css: ["suggested-action"]) { }
        dialog = makeDialog(title: model.title, width: 560, height: 680, content: content, headerEnd: [saveButton])
        on(saveButton, "clicked") { [unowned self] in run { [unowned self] in await save() } }
        adw_dialog_set_can_close(cast(dialog), 0)
        on(dialog, "close-attempt") { [unowned self] in closeAttempt() }
        on(dialog, "closed") { [unowned self] in keepAlive = nil }
        renderJumps()
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
    }

    private func renderJumps() {
        while let child = gtk_widget_get_first_child(jumpList) { gtk_list_box_remove(cast(jumpList), child) }
        for (index, title) in model.jumpTitles.enumerated() {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(row), 0)
            adw_preferences_row_set_title(cast(row), "\(index + 1). \(title)")
            if index > 0 {
                adw_action_row_add_suffix(cast(row), iconButton("go-up-symbolic", tooltip: "Earlier") { [unowned self] in
                    model.moveJumps(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                    renderJumps()
                })
            }
            adw_action_row_add_suffix(cast(row), iconButton("list-remove-symbolic", tooltip: "Remove") { [unowned self] in
                model.removeJumps(atOffsets: IndexSet(integer: index))
                renderJumps()
            })
            gtk_list_box_append(cast(jumpList), row)
        }
        gtk_widget_set_visible(jumpList, model.jumpTitles.isEmpty ? 0 : 1)
    }

    private func showMessages() {
        let fields = [ServerDraft.Field.host, .port, .username].compactMap(model.message(for:))
        adw_preferences_group_set_description(cast(serverGroup), fields.isEmpty ? nil : fields.joined(separator: " "))
        adw_preferences_group_set_description(cast(loginGroup), model.passwordMessage)
        adw_preferences_group_set_description(cast(servicesGroup), model.servicesMessage)
        adw_preferences_group_set_description(cast(jumpGroup), model.jumpMessage ?? "Hosts ssh goes through first, in order (ProxyJump).")
        gtk_label_set_text(cast(errorLabel), model.error ?? "")
        gtk_widget_set_visible(errorLabel, model.error == nil ? 0 : 1)
    }

    private func save() async {
        // A screen for a host that is saved already: ask, never merge silently.
        if let existing = model.sameHostServers.first, model.canSave {
            let folder = existing.groupID.flatMap { id in model.groups.first { $0.id == id }?.name } ?? ServerListModel.ungroupedTitle
            let what = model.screens.map(\.shortTitle).sorted().joined(separator: " and ")
            alert("\(existing.name) Has This Host",
                  "Add \(what) to \(existing.name) (in \(folder)), or keep this as a separate server with its own name and folder?",
                  responses: [Response(id: "cancel", label: "Cancel"), Response(id: "separate", label: "Keep as a Separate Server"),
                              Response(id: "add", label: "Add \(what) to \(existing.name)", look: .suggested)],
                  parent: dialog) { [unowned self] id in
                switch id {
                case "add": run { [unowned self] in if await model.addScreens(to: existing.id) { adw_dialog_force_close(cast(dialog)) } else { showMessages() } }
                case "separate": run { [unowned self] in await commitSave() }
                default: break
                }
            }
            return
        }
        // SSH turned off while screens tunnel through it: warn, offer direct, never break them silently.
        let losing = model.screensLosingSSH
        if !losing.isEmpty, model.canSave {
            alert("Screens Use This Server's SSH",
                  "\(losing.map(\.name).joined(separator: ", ")) reach their screen through this server's SSH. Switch them to a direct connection (the port must be reachable from here), or keep them through SSH?",
                  responses: [Response(id: "cancel", label: "Cancel"), Response(id: "keep", label: "Keep Through SSH"),
                              Response(id: "direct", label: "Switch to Direct", look: .suggested)],
                  parent: dialog) { [unowned self] id in
                guard id != "cancel" else { return }
                run { [unowned self] in await commitSave(screensGoDirect: id == "direct") }
            }
            return
        }
        await commitSave()
    }

    private func commitSave(screensGoDirect: Bool = false) async {
        gtk_widget_set_sensitive(saveButton, 0)
        let saved = await model.save(screensGoDirect: screensGoDirect)
        gtk_widget_set_sensitive(saveButton, 1)
        showMessages()
        guard saved != nil else { return }
        adw_dialog_force_close(cast(dialog))
    }

    private func closeAttempt() {
        guard model.hasChanges else { return adw_dialog_force_close(cast(dialog)) }
        alert("Discard Changes?", "The server is not saved.",
              responses: [Response(id: "keep", label: "Keep Editing"), Response(id: "discard", label: "Discard", look: .destructive)],
              parent: dialog) { [unowned self] id in
            if id == "discard" { adw_dialog_force_close(cast(dialog)) }
        }
    }
}
