// The remote desktop login sheet (only when needed: no saved login, a refused one, or "ask every time") and the
// remote desktop editor (kind, host/port, Through server / own SSH connection / direct with a warning, login with
// Copy from SSH, clipboard, ask every time).
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

@MainActor
final class RemoteDesktopLoginDialog {
    private let sheet: RemoteDesktopLoginSheet
    private let parent: Widget
    private let done: (RemoteDesktopConnectPlan.SheetChoice?) -> Void
    private var dialog: Widget!
    private var answered = false
    private var focusTarget: Widget?
    private var keepAlive: RemoteDesktopLoginDialog?

    init(sheet: RemoteDesktopLoginSheet, desktop: RemoteDesktop, parent: Widget,
         done: @escaping (RemoteDesktopConnectPlan.SheetChoice?) -> Void) {
        self.sheet = sheet
        self.parent = parent
        self.done = done
        let page = adw_preferences_page_new()!
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_description(cast(group), sheet.error)
        adw_preferences_page_add(cast(page), cast(group))
        let saved = sheet.savedPasswords
        var savedIndex = saved.firstIndex { $0.id == sheet.preselected }.map { $0 + 1 } ?? 0
        let user = adw_entry_row_new()!
        adw_preferences_row_set_title(cast(user), "User")
        gtk_editable_set_text(cast(user), sheet.username)
        gtk_widget_set_visible(user, sheet.needsUsername ? 1 : 0)
        let password = adw_password_entry_row_new()!
        adw_preferences_row_set_title(cast(password), desktop.kind == .vnc ? "VNC Password" : "Password")
        let save = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(save), "Save to Vault")
        adw_action_row_set_subtitle(cast(save), "Stored once the login works.")
        adw_switch_row_set_active(cast(save), 1)
        let pick = comboRow("Saved Password", titles: ["Type a password"] + saved.map(\.label), selected: savedIndex) { i in
            savedIndex = i
            gtk_widget_set_visible(password, i == 0 ? 1 : 0)
            gtk_widget_set_visible(save, i == 0 ? 1 : 0)
        }
        gtk_widget_set_visible(password, savedIndex == 0 ? 1 : 0)
        gtk_widget_set_visible(save, savedIndex == 0 ? 1 : 0)
        for w in [pick, user, password, save] { adw_preferences_group_add(cast(group), w) }
        let without = button("Continue Without (log in on the screen)", css: ["flat"]) { [unowned self] in finish(.withoutLogin) }
        gtk_widget_set_margin_top(without, 12)
        adw_preferences_group_add(cast(group), without)

        let connect = button("Connect", css: ["suggested-action"]) { [unowned self] in
            let u = string(gtk_editable_get_text(cast(user)))
            let name: String? = sheet.needsUsername && !u.isEmpty ? u : nil
            if savedIndex > 0 {
                finish(.saved(saved[savedIndex - 1].id, username: name))
            } else {
                let p = string(gtk_editable_get_text(cast(password)))
                guard !p.isEmpty else { return gtk_widget_add_css_class(password, "error") }
                finish(.typed(username: name, password: p, save: adw_switch_row_get_active(cast(save)) != 0))
            }
        }
        on(password, "entry-activated") { gtk_widget_activate(connect) }
        focusTarget = savedIndex == 0 ? password : connect
        dialog = makeDialog(title: "Log In to \(desktop.name)", width: 460, height: 440, content: page, headerEnd: [connect])
        on(dialog, "closed") { [unowned self] in
            if !answered { answered = true; done(nil) }
            keepAlive = nil
        }
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
        if let focusTarget { gtk_widget_grab_focus(focusTarget) }
    }

    private func finish(_ choice: RemoteDesktopConnectPlan.SheetChoice) {
        guard !answered else { return }
        answered = true
        let done = self.done
        let me = self
        adw_dialog_close(cast(dialog))
        done(choice)
        _ = me
    }
}

@MainActor
final class RemoteDesktopEditorDialog {
    private var form: RemoteDesktopForm
    private let original: RemoteDesktop?
    private unowned let app: AppController
    private let parent: Widget
    private var dialog: Widget!
    private var connectionGroup: Widget!
    private var mainGroup: Widget!
    private var userRow: Widget!
    private var domainRow: Widget!
    private var serverRow: Widget!
    private var errorLabel: Widget!
    private var keepAlive: RemoteDesktopEditorDialog?

    init(desktop: RemoteDesktop?, groupID: UUID? = nil, app: AppController, parent: Widget) {
        let vault = app.vault ?? Vault()
        form = RemoteDesktopForm(desktop: desktop, servers: vault.servers, groupID: groupID)
        original = desktop
        self.app = app
        self.parent = parent
        let page = adw_preferences_page_new()!

        mainGroup = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(mainGroup), "Remote Desktop")
        adw_preferences_page_add(cast(page), cast(mainGroup))
        adw_preferences_group_add(cast(mainGroup), entryRow("Name", text: form.name) { [unowned self] in form.name = $0 })
        let kinds = RemoteDesktop.Kind.allCases
        let portRow = entryRow("Port", text: form.port) { [unowned self] in form.port = $0 }
        adw_preferences_group_add(cast(mainGroup), comboRow("Kind", titles: kinds.map(\.title), selected: kinds.firstIndex(of: form.kind) ?? 0) { [unowned self] i in
            form.setKind(kinds[i])
            gtk_editable_set_text(cast(portRow), form.port)
            refresh()
        })
        adw_preferences_group_add(cast(mainGroup), entryRow("Host (as the SSH server sees it)", text: form.host) { [unowned self] in form.host = $0 })
        adw_preferences_group_add(cast(mainGroup), portRow)
        let groups = vault.groups
        adw_preferences_group_add(cast(mainGroup), comboRow("Folder", titles: [ServerListModel.ungroupedTitle] + groups.map(\.name),
                                                             selected: (groups.firstIndex { $0.id == form.groupID } ?? -1) + 1) { [unowned self] i in
            form.groupID = i == 0 ? nil : groups[i - 1].id
        })

        connectionGroup = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(connectionGroup), "Connection")
        adw_preferences_page_add(cast(page), cast(connectionGroup))
        let transports: [RemoteDesktop.Transport] = [.sshShared, .sshSeparate, .direct]
        let transportTitles = ["Through an SSH server", "Own SSH connection to it", "Direct (no SSH)"]
        adw_preferences_group_add(cast(connectionGroup), comboRow("Route", titles: transportTitles,
                                                                   selected: transports.firstIndex(of: form.transport) ?? 0) { [unowned self] i in
            form.transport = transports[i]
            refresh()
        })
        let servers = vault.servers
        serverRow = comboRow("SSH Server", titles: servers.isEmpty ? ["No servers yet"] : servers.map(\.name),
                             selected: servers.firstIndex { $0.id == form.tunnelServerID } ?? 0) { [unowned self] i in
            if servers.indices.contains(i) { form.tunnelServerID = servers[i].id }
        }
        adw_preferences_group_add(cast(connectionGroup), serverRow)

        let login = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(login), "Login")
        adw_preferences_page_add(cast(page), cast(login))
        userRow = entryRow("User (Mac or Windows account)", text: form.username) { [unowned self] in form.username = $0 }
        adw_preferences_group_add(cast(login), userRow)
        domainRow = entryRow("Domain (RDP)", text: form.domain) { [unowned self] in form.domain = $0 }
        adw_preferences_group_add(cast(login), domainRow)
        let passwords = vault.credentials.filter { if case .password = $0.kind { true } else { false } }
        let passwordRow = comboRow("Password", titles: ["Ask when connecting"] + passwords.map(\.label),
                                   selected: (passwords.firstIndex { $0.id == form.credentialID } ?? -1) + 1) { [unowned self] i in
            form.credentialID = i == 0 ? nil : passwords[i - 1].id
        }
        adw_preferences_group_add(cast(login), passwordRow)
        let copy = button("Copy from SSH", css: ["flat"]) { [unowned self] in
            guard let serverID = form.tunnelServerID, let vault = app.vault,
                  let probe = try? RemoteDesktop(name: "x", kind: form.kind, host: "x").copyingLogin(from: serverID, in: vault) else { return }
            form.username = probe.username ?? ""
            gtk_editable_set_text(cast(userRow), form.username)
            if let id = probe.credentialID, let i = passwords.firstIndex(where: { $0.id == id }) {
                form.credentialID = id
                adw_combo_row_set_selected(cast(passwordRow), guint(i + 1))
            }
        }
        gtk_widget_set_tooltip_text(copy, "The SSH server's user, and its password when it logs in with one (a key cannot open a screen).")
        adw_preferences_group_set_header_suffix(cast(login), copy)
        let ask = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(ask), "Ask Every Time")
        adw_switch_row_set_active(cast(ask), form.askEveryTime ? 1 : 0)
        onNotify(ask, "active") { [unowned self] in form.askEveryTime = adw_switch_row_get_active(cast(ask)) != 0 }
        adw_preferences_group_add(cast(login), ask)

        let screen = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(screen), "Screen")
        adw_preferences_page_add(cast(page), cast(screen))
        let clip = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(clip), "Clipboard")
        adw_action_row_set_subtitle(cast(clip), "Off: the screen never sees what you copy here. On: a paste button types it there.")
        adw_switch_row_set_active(cast(clip), form.shareClipboard ? 1 : 0)
        onNotify(clip, "active") { [unowned self] in form.shareClipboard = adw_switch_row_get_active(cast(clip)) != 0 }
        adw_preferences_group_add(cast(screen), clip)

        errorLabel = label("", css: ["error"], wrap: true)
        setMargins(errorLabel, 12)
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(cast(content), errorLabel)
        gtk_box_append(cast(content), page)
        gtk_widget_set_vexpand(page, 1)
        let saveButton = button("Save", css: ["suggested-action"]) { [unowned self] in run { [unowned self] in await save() } }
        dialog = makeDialog(title: desktop == nil ? "New Remote Desktop" : desktop!.name, width: 560, height: 640,
                            content: content, headerEnd: [saveButton])
        on(dialog, "closed") { [unowned self] in keepAlive = nil }
        refresh()
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
    }

    private func refresh() {
        gtk_widget_set_visible(serverRow, form.transport == .direct ? 0 : 1)
        gtk_widget_set_visible(userRow, form.kind.usesUsername ? 1 : 0)
        gtk_widget_set_visible(domainRow, form.kind == .rdp ? 1 : 0)
        adw_preferences_group_set_description(cast(connectionGroup), form.directWarning
            ?? (form.kind == .appleScreenSharing ? "Keep the Mac patched and its port 5900 closed to the network: reach it through SSH." : nil))
        gtk_widget_set_visible(errorLabel, 0)
    }

    private func save() async {
        guard let document = app.document else { return }
        let issues = form.issues
        guard issues.isEmpty else {
            gtk_label_set_text(cast(errorLabel), issues.map(RemoteDesktopForm.message).joined(separator: " "))
            gtk_widget_set_visible(errorLabel, 1)
            return
        }
        do {
            let desktop = try form.makeDesktop(id: original?.id ?? UUID())
            let vault = document.vault
            let next = original == nil ? try vault.addingRemoteDesktop(desktop) : try vault.updatingRemoteDesktop(desktop)
            try await document.commit(next)
            adw_dialog_close(cast(dialog))
        } catch {
            gtk_label_set_text(cast(errorLabel), (error as? LocalizedError)?.errorDescription ?? "\(error)")
            gtk_widget_set_visible(errorLabel, 1)
        }
    }
}
