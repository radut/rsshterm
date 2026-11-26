// Quick Connect: hosts (one, several or a pasted list) -> user (when a host has no user@) -> login (automatic vault
// keys, a saved key or password, or a password typed once) -> one tab per host running OpenSSH -> "Save to" a
// folder afterwards. Bound to QuickConnectModel.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

@MainActor
final class QuickConnectDialog {
    private let model: QuickConnectModel
    private unowned let window: MainWindow
    private var dialog: Widget!
    private var hostsList: Widget!
    private var invalid: Widget!
    private var userGroup: Widget!
    private var loginGroup: Widget!
    private var saveGroup: Widget!
    private var errorLabel: Widget!
    private var choice: QuickLoginChoice = .automatic
    private var destination: ScanDestination = .ungrouped
    private var savePassword = false
    private var keepAlive: QuickConnectDialog?

    init(model: QuickConnectModel, window: MainWindow) {
        self.model = model
        self.window = window
        let page = adw_preferences_page_new()!

        let hostsGroup = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(hostsGroup), "Hosts")
        adw_preferences_group_set_description(cast(hostsGroup), "host, user@host:port, or a pasted list (one tab each).")
        adw_preferences_page_add(cast(page), cast(hostsGroup))
        let entry = adw_entry_row_new()!
        adw_preferences_row_set_title(cast(entry), "Add Hosts")
        adw_entry_row_set_show_apply_button(cast(entry), 1)
        let add = { [unowned self] in
            model.addHosts(string(gtk_editable_get_text(cast(entry))))
            gtk_editable_set_text(cast(entry), "")
        }
        on(entry, "apply", add)
        on(entry, "entry-activated", add)
        adw_preferences_group_add(cast(hostsGroup), entry)
        hostsList = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(hostsList), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(hostsList, "boxed-list")
        gtk_widget_set_margin_top(hostsList, 6)
        adw_preferences_group_add(cast(hostsGroup), hostsList)
        invalid = label("", css: ["error", "caption"], wrap: true)
        adw_preferences_group_add(cast(hostsGroup), invalid)
        adw_preferences_group_add(cast(hostsGroup), entryRow("Port", text: model.port) { model.port = $0 })

        userGroup = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(userGroup), "User")
        adw_preferences_page_add(cast(page), cast(userGroup))
        let users = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(cast(users), GTK_SELECTION_NONE)
        for user in model.users {
            gtk_flow_box_append(cast(users), button(user, css: ["pill"]) { model.chooseUser(user) })
        }
        adw_preferences_group_add(cast(userGroup), users)
        let other = adw_entry_row_new()!
        adw_preferences_row_set_title(cast(other), "Other User")
        adw_entry_row_set_show_apply_button(cast(other), 1)
        on(other, "apply") { model.chooseUser(string(gtk_editable_get_text(cast(other)))) }
        on(other, "entry-activated") { model.chooseUser(string(gtk_editable_get_text(cast(other)))) }
        adw_preferences_group_add(cast(userGroup), other)

        loginGroup = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(loginGroup), "Log In With")
        adw_preferences_page_add(cast(page), cast(loginGroup))
        let saved = model.savedLogins
        let automatic = model.automaticLogins.count
        let titles = ["Automatic (\(automatic) vault key\(automatic == 1 ? "" : "s"))"] + saved.map(\.label) + ["Password…"]
        let pw = adw_password_entry_row_new()!
        adw_preferences_row_set_title(cast(pw), "Password")
        gtk_widget_set_visible(pw, 0)
        on(pw, "changed") { model.password = string(gtk_editable_get_text(cast(pw))) }
        adw_preferences_group_add(cast(loginGroup), comboRow("Login", titles: titles, selected: 0) { [unowned self] i in
            choice = i == 0 ? .automatic : i <= saved.count ? .credential(saved[i - 1].id) : .password
            gtk_widget_set_visible(pw, choice == .password ? 1 : 0)
        })
        adw_preferences_group_add(cast(loginGroup), pw)
        let connect = button("Connect", css: ["suggested-action", "pill"]) { [unowned self] in connectNow() }
        gtk_widget_set_margin_top(connect, 12)
        gtk_widget_set_halign(connect, GTK_ALIGN_CENTER)
        adw_preferences_group_add(cast(loginGroup), connect)

        saveGroup = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(saveGroup), "Save These Hosts")
        adw_preferences_page_add(cast(page), cast(saveGroup))
        let groups = model.document.vault.groups
        adw_preferences_group_add(cast(saveGroup), comboRow("Save To", titles: [ServerListModel.ungroupedTitle] + groups.map(\.name)
                                                             + ["New Folder “Quick Connect”"], selected: 0) { [unowned self] i in
            destination = i == 0 ? .ungrouped : i <= groups.count ? .folder(groups[i - 1].id) : .newFolder("Quick Connect")
        })
        let savePw = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(savePw), "Save the Password Too")
        onNotify(savePw, "active") { [unowned self] in savePassword = adw_switch_row_get_active(cast(savePw)) != 0 }
        adw_preferences_group_add(cast(saveGroup), savePw)
        // Open As: SSH by default; RDP and VNC save the screens with the servers.
        let sshRow = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(sshRow), "Open As SSH")
        adw_switch_row_set_active(cast(sshRow), 1)
        onNotify(sshRow, "active") { [unowned self] in model.sshEnabled = adw_switch_row_get_active(cast(sshRow)) != 0 }
        adw_preferences_group_add(cast(saveGroup), sshRow)
        for service in ScreenService.allCases {
            let row = adw_switch_row_new()!
            adw_preferences_row_set_title(cast(row), "Also " + service.title)
            onNotify(row, "active") { [unowned self] in
                if adw_switch_row_get_active(cast(row)) != 0 { model.screens.insert(service) } else { model.screens.remove(service) }
            }
            adw_preferences_group_add(cast(saveGroup), row)
        }
        let saveButton = button("Save", css: ["pill"]) { [unowned self] in run { [unowned self] in await save() } }
        gtk_widget_set_margin_top(saveButton, 12)
        gtk_widget_set_halign(saveButton, GTK_ALIGN_CENTER)
        adw_preferences_group_add(cast(saveGroup), saveButton)

        errorLabel = label("", css: ["error"], wrap: true)
        setMargins(errorLabel, 12)
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(cast(content), errorLabel)
        gtk_box_append(cast(content), page)
        gtk_widget_set_vexpand(page, 1)
        dialog = makeDialog(title: "Quick Connect", width: 520, height: 640, content: content)
        on(dialog, "closed") { [unowned self] in keepAlive = nil }
        observe({ [model] in _ = model.step; _ = model.hosts; _ = model.invalidTokens; _ = model.error }) { [weak self] in
            self?.render()
        }
        render()
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), window.window)
    }

    private func render() {
        while let child = gtk_widget_get_first_child(hostsList) { gtk_list_box_remove(cast(hostsList), child) }
        for (index, host) in model.hosts.enumerated() {
            let r = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(r), 0)
            adw_preferences_row_set_title(cast(r), host.displayName)
            adw_action_row_add_suffix(cast(r), iconButton("list-remove-symbolic", tooltip: "Remove") { [unowned self] in
                model.removeHosts(atOffsets: IndexSet(integer: index))
            })
            gtk_list_box_append(cast(hostsList), r)
        }
        gtk_widget_set_visible(hostsList, model.hosts.isEmpty ? 0 : 1)
        gtk_label_set_text(cast(invalid), model.invalidTokens.isEmpty ? "" : "Not hosts: " + model.invalidTokens.joined(separator: ", "))
        gtk_widget_set_visible(invalid, model.invalidTokens.isEmpty ? 0 : 1)
        let step = model.step
        gtk_widget_set_visible(userGroup, step == .user ? 1 : 0)
        gtk_widget_set_visible(loginGroup, step == .login ? 1 : 0)
        gtk_widget_set_visible(saveGroup, step == .connecting ? 1 : 0)
        gtk_label_set_text(cast(errorLabel), model.error ?? "")
        gtk_widget_set_visible(errorLabel, model.error == nil ? 0 : 1)
    }

    private func connectNow() {
        guard let plans = model.connect(with: choice) else { return }
        for plan in plans { window.openCommand(QuickConnectCommand.argv(plan), title: plan.target.displayName) }
    }

    /// Screens for a host that is saved already: ask whether they join that server, never decided silently.
    private func save() async {
        let matches = model.savedServersForScreens
        guard !matches.isEmpty else { return await save(joining: false) }
        let names = matches.map(\.name).joined(separator: ", ")
        alert("\(names) Already Saved",
              "Add the ticked screens to \(names), or save separate servers with their own names?",
              responses: [Response(id: "cancel", label: "Cancel"), Response(id: "separate", label: "Keep Separate"),
                          Response(id: "join", label: "Add to \(matches.count == 1 ? matches[0].name : "Saved Servers")", look: .suggested)],
              parent: dialog) { [unowned self] id in
            guard id != "cancel" else { return }
            run { [unowned self] in await save(joining: id == "join") }
        }
    }

    private func save(joining: Bool) async {
        let credentialID: UUID? = if case .credential(let id) = choice { id } else { nil }
        let saved = await model.save(to: destination, credentialID: credentialID, savePassword: savePassword,
                                     screensJoinSavedServers: joining)
        if !saved.isEmpty || model.error == nil {
            window.toast("\(saved.count) server(s) saved.")
            adw_dialog_close(cast(dialog))
        }
    }
}
