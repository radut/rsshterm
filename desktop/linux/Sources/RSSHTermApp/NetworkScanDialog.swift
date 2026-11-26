// Scan Network: an address range (prefilled with this machine's subnet) and ports, progress, the hosts that
// answered with checkboxes (already saved ones greyed), and Add (N) as servers into a folder, with a user, a login
// (saved password or key, or a new password saved once) and saved servers to jump through. NetworkScanModel.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit

@MainActor
final class NetworkScanDialog {
    private let model: NetworkScanModel
    private let parent: Widget
    private var dialog: Widget!
    private var startButton: Widget!
    private var progress: Widget!
    private var results: Widget!
    private var addButton: Widget!
    private var errorLabel: Widget!
    private var jumpList: Widget!
    private var username = "you"
    private var destination: ScanDestination?
    private var keepAlive: NetworkScanDialog?

    init(model: NetworkScanModel, parent: Widget) {
        self.model = model
        self.parent = parent
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        setMargins(box, 12)
        let form = adw_preferences_group_new()!
        adw_preferences_group_add(cast(form), entryRow("Addresses (range or CIDR)", text: model.rangeText) { model.rangeText = $0 })
        adw_preferences_group_add(cast(form), entryRow("Ports", text: model.portsText) { model.portsText = $0 })
        let only = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(only), "Only Hosts With an Open Port")
        adw_switch_row_set_active(cast(only), model.onlySSH ? 1 : 0)
        onNotify(only, "active") { model.onlySSH = adw_switch_row_get_active(cast(only)) != 0 }
        adw_preferences_group_add(cast(form), only)
        gtk_box_append(cast(box), form)

        progress = gtk_progress_bar_new()
        gtk_progress_bar_set_show_text(cast(progress), 1)
        gtk_box_append(cast(box), progress)
        errorLabel = label("", css: ["error"], wrap: true)
        gtk_box_append(cast(box), errorLabel)

        let selectRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        gtk_box_append(cast(selectRow), button("Select All", css: ["flat"]) { model.selectAll() })
        gtk_box_append(cast(selectRow), button("Select None", css: ["flat"]) { model.selectNone() })
        gtk_box_append(cast(box), selectRow)

        results = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(results), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(results, "boxed-list")
        gtk_box_append(cast(box), results)

        let save = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(save), "Add as Servers")
        adw_preferences_group_add(cast(save), entryRow("User", text: username) { [unowned self] in username = $0 })
        let groups = model.document.vault.groups
        adw_preferences_group_add(cast(save), comboRow("Save To", titles: ["New Folder (the range)", ServerListModel.ungroupedTitle] + groups.map(\.name),
                                                        selected: 0) { [unowned self] i in
            destination = i == 0 ? nil : i == 1 ? .ungrouped : .folder(groups[i - 2].id)
        })
        let passwords = model.document.vault.credentials(for: .password), keys = model.document.vault.credentials(for: .key)
        let logins: [ServerEditorModel.Login] = [.none] + passwords.map { .saved($0.id) } + keys.map { .saved($0.id) } + [.newPassword]
        let titles = ["None (agent keys, or ask)"] + passwords.map { "Password: \($0.label)" } + keys.map { "Key: \($0.label)" }
            + ["New Password…"]
        let passwordRow = adw_password_entry_row_new()!
        adw_preferences_row_set_title(cast(passwordRow), "New Password (saved once for all)")
        on(passwordRow, "changed") { model.newPassword = string(gtk_editable_get_text(cast(passwordRow))) }
        adw_preferences_group_add(cast(save), comboRow("Log In With", titles: titles, selected: 0) { i in
            model.addLogin = logins[i]
            gtk_widget_set_visible(passwordRow, model.addLogin == .newPassword ? 1 : 0)
        })
        adw_preferences_group_add(cast(save), passwordRow)
        gtk_widget_set_visible(passwordRow, 0)
        gtk_box_append(cast(box), save)

        let jumps = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(jumps), "Jump Through")
        adw_preferences_group_set_description(cast(jumps), "Saved servers ssh goes through first, in order (ProxyJump).")
        jumpList = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(jumpList), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(jumpList, "boxed-list")
        adw_preferences_group_add(cast(jumps), jumpList)
        let candidates = model.jumpCandidates
        let serverPick = gtk_drop_down_new(cast(stringList(["Add saved server…"] + candidates.map(\.name))), nil)!
        gtk_widget_set_margin_top(serverPick, 6)
        gtk_widget_set_sensitive(serverPick, candidates.isEmpty ? 0 : 1)
        onNotify(serverPick, "selected") { [unowned self] in
            let i = Int(gtk_drop_down_get_selected(cast(serverPick)))
            guard i > 0 else { return }
            model.addJump(server: candidates[i - 1].id)
            gtk_drop_down_set_selected(cast(serverPick), 0)
            renderJumps()
        }
        adw_preferences_group_add(cast(jumps), serverPick)
        gtk_box_append(cast(box), jumps)

        startButton = button("Scan", css: ["suggested-action"]) { [unowned self] in
            model.isScanning ? model.stop() : model.start()
        }
        addButton = button("Add", css: ["suggested-action"]) { [unowned self] in run { [unowned self] in await add() } }
        dialog = makeDialog(title: "Scan Network", width: 600, height: 680, content: scrolled(box), headerEnd: [addButton],
                            headerStart: [startButton])
        on(dialog, "closed") { [unowned self] in
            model.stop()
            keepAlive = nil
        }
        observe({ [model] in
            _ = model.visible; _ = model.selection; _ = model.progress; _ = model.isScanning; _ = model.error
        }) { [weak self] in self?.render() }
        render()
        renderJumps()
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
    }

    private func render() {
        gtk_button_set_label(cast(startButton), model.isScanning ? "Stop" : "Scan")
        if let p = model.progress {
            gtk_progress_bar_set_fraction(cast(progress), p.fraction)
            gtk_progress_bar_set_text(cast(progress), "\(p.done) of \(p.total) addresses")
        } else {
            gtk_progress_bar_set_fraction(cast(progress), 0)
            gtk_progress_bar_set_text(cast(progress), "Not scanned yet")
        }
        gtk_label_set_text(cast(errorLabel), model.error ?? "")
        gtk_widget_set_visible(errorLabel, model.error == nil ? 0 : 1)
        while let child = gtk_widget_get_first_child(results) { gtk_list_box_remove(cast(results), child) }
        for host in model.visible {
            let r = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(r), 0)
            adw_preferences_row_set_title(cast(r), host.dnsName.map { "\($0) (\(host.host))" } ?? host.host)
            var subtitle = "port \(host.port) · \(host.serviceTitle)"
            if let b = host.banner { subtitle += " · \(b.software) \(b.comment)" }
            let saved = model.isSaved(host)
            if saved { subtitle += " · already saved" }
            adw_action_row_set_subtitle(cast(r), subtitle)
            let check = gtk_check_button_new()!
            gtk_check_button_set_active(cast(check), model.selection.contains(host.id) && !saved ? 1 : 0)
            gtk_widget_set_sensitive(check, saved ? 0 : 1)
            gtk_widget_set_sensitive(r, saved ? 0 : 1)
            on(check, "toggled") { [unowned self] in
                let on = gtk_check_button_get_active(cast(check)) != 0
                if on != model.selection.contains(host.id) { onMain { [unowned self] in model.toggle(host) } }
            }
            adw_action_row_add_prefix(cast(r), check)
            adw_action_row_set_activatable_widget(cast(r), check)
            gtk_list_box_append(cast(results), r)
        }
        let n = model.selectedHosts.count
        gtk_button_set_label(cast(addButton), n == 0 ? "Add" : "Add (\(n))")
        gtk_widget_set_sensitive(addButton, n == 0 ? 0 : 1)
    }

    private func renderJumps() {
        while let child = gtk_widget_get_first_child(jumpList) { gtk_list_box_remove(cast(jumpList), child) }
        for (index, title) in model.jumpTitles.enumerated() {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(row), 0)
            adw_preferences_row_set_title(cast(row), "\(index + 1). \(title)")
            if index > 0 {
                adw_action_row_add_suffix(cast(row), iconButton("go-up-symbolic", tooltip: "Earlier") { [unowned self] in
                    model.moveJumpEarlier(index)
                    renderJumps()
                })
            }
            adw_action_row_add_suffix(cast(row), iconButton("list-remove-symbolic", tooltip: "Remove") { [unowned self] in
                model.removeJump(index)
                renderJumps()
            })
            gtk_list_box_append(cast(jumpList), row)
        }
        gtk_widget_set_visible(jumpList, model.jumpTitles.isEmpty ? 0 : 1)
    }

    /// Screens (3389, 5900) of hosts already saved: ask whether they join those servers, never decided silently.
    private func add() async {
        let saved = model.savedServersForScreens
        guard !saved.isEmpty else { return await add(joining: false) }
        let names = saved.map(\.name).joined(separator: ", ")
        alert("Some Screens Belong to Saved Servers",
              "Remote desktop or VNC ports answered on hosts already saved as \(names). Add those screens to the saved servers, or keep them as separate servers?",
              responses: [Response(id: "cancel", label: "Cancel"), Response(id: "separate", label: "Keep Separate"),
                          Response(id: "join", label: "Add to \(saved.count == 1 ? saved[0].name : "Saved Servers")", look: .suggested)],
              parent: dialog) { [unowned self] id in
            guard id != "cancel" else { return }
            run { [unowned self] in await add(joining: id == "join") }
        }
    }

    private func add(joining: Bool) async {
        let target = destination ?? .newFolder(model.scannedRange.isEmpty ? "Scanned" : model.scannedRange)
        let user = username.isEmpty ? "you" : username
        let added = await model.addSelected(username: user, login: model.discoveredLogin(username: user),
                                            jumpHosts: model.addJumps, screensJoinSavedServers: joining, to: target)
        if added > 0 {
            message("Servers Added", "\(added) server(s) added.", parent: dialog)
        }
    }
}
