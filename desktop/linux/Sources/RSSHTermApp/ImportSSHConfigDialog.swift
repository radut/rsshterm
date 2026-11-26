// File › Import ~/.ssh/config: one row per Host alias (checkbox; "already saved" unchecked; problems greyed with
// the reason), the includes and notes below, a Save-to popup, and "Import their key files": unencrypted
// IdentityFile keys come into the vault and become the servers' logins (encrypted ones are listed to import in Keys).
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit

@MainActor
final class ImportSSHConfigDialog {
    private let list: ServerListModel
    private let credentials: CredentialsModel
    private let parent: Widget
    private var dialog: Widget!
    private var checks: [(SSHConfigImportCandidate, Widget)] = []
    private var destination: ScanDestination = .newFolder("Imported")
    private var importKeys = true
    private var keepAlive: ImportSSHConfigDialog?
    private let home: String

    init(list: ServerListModel, credentials: CredentialsModel, sshConfigText: String, home: String, user: String, parent: Widget) {
        self.list = list
        self.credentials = credentials
        self.parent = parent
        self.home = home
        let (candidates, result) = list.importCandidates(sshConfig: sshConfigText, defaultUser: user)
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        setMargins(box, 12)
        let rows = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(cast(rows), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(rows, "boxed-list")
        for candidate in candidates {
            let r = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(r), 0)
            adw_preferences_row_set_title(cast(r), candidate.entry.alias)
            let d = candidate.draft
            var subtitle = "\(d.username.isEmpty ? user : d.username)@\(d.host)" + (d.port == "22" ? "" : ":\(d.port)")
            if let jump = candidate.entry.proxyJump { subtitle += " · via \(jump)" }
            if candidate.existing != nil { subtitle += " · already saved" }
            if let problem = candidate.problem { subtitle += " · \(problem)" }
            adw_action_row_set_subtitle(cast(r), subtitle)
            let check = gtk_check_button_new()!
            gtk_check_button_set_active(cast(check), candidate.isImportable && candidate.existing == nil ? 1 : 0)
            gtk_widget_set_sensitive(check, candidate.isImportable ? 1 : 0)
            gtk_widget_set_sensitive(r, candidate.isImportable ? 1 : 0)
            adw_action_row_add_prefix(cast(r), check)
            adw_action_row_set_activatable_widget(cast(r), check)
            gtk_list_box_append(cast(rows), r)
            checks.append((candidate, check))
        }
        if candidates.isEmpty {
            gtk_box_append(cast(box), label("No Host entries to import were found in ~/.ssh/config.", css: ["dim-label"]))
        } else {
            gtk_box_append(cast(box), rows)
        }
        let notes = result.includes.map { "Include \($0) (not followed)" } + result.notes
        if !notes.isEmpty { gtk_box_append(cast(box), label(notes.joined(separator: "\n"), css: ["dim-label", "caption"], wrap: true)) }

        let options = adw_preferences_group_new()!
        let groups = list.vault.groups
        let titles = ["New Folder “Imported”", ServerListModel.ungroupedTitle] + groups.map(\.name)
        adw_preferences_group_add(cast(options), comboRow("Save To", titles: titles, selected: 0) { [unowned self] i in
            destination = i == 0 ? .newFolder("Imported") : i == 1 ? .ungrouped : .folder(groups[i - 2].id)
        })
        let keysRow = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(keysRow), "Import Their Key Files")
        adw_action_row_set_subtitle(cast(keysRow), "IdentityFile keys without a passphrase become the servers' logins.")
        adw_switch_row_set_active(cast(keysRow), 1)
        onNotify(keysRow, "active") { [unowned self] in importKeys = adw_switch_row_get_active(cast(keysRow)) != 0 }
        adw_preferences_group_add(cast(options), keysRow)
        gtk_box_append(cast(box), options)

        let importButton = button("Import", css: ["suggested-action"]) { [unowned self] in run { [unowned self] in await doImport() } }
        gtk_widget_set_sensitive(importButton, candidates.contains { $0.isImportable } ? 1 : 0)
        dialog = makeDialog(title: "Import ~/.ssh/config", width: 620, height: 560, content: scrolled(box), headerEnd: [importButton])
        on(dialog, "closed") { [unowned self] in keepAlive = nil }
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
    }

    private func doImport() async {
        let chosen = checks.filter { gtk_check_button_get_active(cast($0.1)) != 0 }.map(\.0)
        guard !chosen.isEmpty else { return }
        var keyIDs: [String: UUID] = [:]
        var skipped: [String] = []
        if importKeys {
            for path in Set(chosen.compactMap { $0.entry.identityFiles.first }) {
                let full = path.hasPrefix("~/") ? home + "/" + path.dropFirst(2) : path
                guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
                guard case .success(let preview) = credentials.previewKey(text), !preview.isEncrypted else {
                    skipped.append(path)
                    continue
                }
                let label = preview.comment.flatMap { $0.isEmpty ? nil : $0 } ?? (full as NSString).lastPathComponent
                if let credential = await credentials.importKey(text, passphrase: nil, label: label) { keyIDs[path] = credential.id }
            }
        }
        let added = await list.importServers(chosen, to: destination) { entry in keyIDs[entry.identityFiles.first ?? ""] }
        var text = "\(added) server(s) imported."
        if !skipped.isEmpty { text += " Keys with a passphrase were not imported: \(skipped.joined(separator: ", ")); import them in Keys and Passwords." }
        if let error = list.error { text += " \(error)" }
        adw_dialog_close(cast(dialog))
        message("Import Finished", text, parent: parent)
    }
}
