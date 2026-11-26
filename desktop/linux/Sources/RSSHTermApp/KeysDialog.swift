// Keys & Passwords: every credential with what uses it. Add a password, import a key file (OpenSSH, PEM, PuTTY;
// passphrase asked when it is encrypted), generate an ed25519 key, rename, delete (refused while a server uses it),
// copy a public key; the private key only after the master password. Bound to CredentialsModel.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

@MainActor
final class KeysDialog {
    private let model: CredentialsModel
    private unowned let app: AppController
    private let parent: Widget
    private var dialog: Widget!
    private var list: Widget!
    private var errorLabel: Widget!
    private var keepAlive: KeysDialog?

    init(app: AppController, model: CredentialsModel, parent: Widget) {
        self.model = model
        self.app = app
        self.parent = parent
        list = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(list, "boxed-list")
        errorLabel = label("", css: ["error"], wrap: true)
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        setMargins(box, 12)
        gtk_box_append(cast(box), label("The built-in ssh-agent offers these keys to every terminal while the vault is unlocked.",
                                        css: ["dim-label"], wrap: true))
        gtk_box_append(cast(box), errorLabel)
        gtk_box_append(cast(box), list)
        let add = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(add), "list-add-symbolic")
        gtk_widget_set_tooltip_text(add, "Add")
        let popover = gtk_popover_new()!
        let menu = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        for (title, action) in [("Generate ed25519 Key…", { [unowned self] in generate() }),
                                ("Import Key File…", { [unowned self] in importFile() }),
                                ("Add Password…", { [unowned self] in addPassword() })] as [(String, () -> Void)] {
            let b = button(title, css: ["flat"]) {
                gtk_popover_popdown(cast(popover))
                action()
            }
            gtk_box_append(cast(menu), b)
        }
        gtk_popover_set_child(cast(popover), menu)
        gtk_menu_button_set_popover(cast(add), popover)
        dialog = makeDialog(title: "Keys and Passwords", width: 680, height: 520, content: scrolled(box), headerStart: [add])
        on(dialog, "closed") { [unowned self] in keepAlive = nil }
        observe({ [model] in _ = model.rows; _ = model.error }) { [weak self] in self?.render() }
        render()
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
    }

    private func render() {
        gtk_label_set_text(cast(errorLabel), model.error ?? "")
        gtk_widget_set_visible(errorLabel, model.error == nil ? 0 : 1)
        while let child = gtk_widget_get_first_child(list) { gtk_list_box_remove(cast(list), child) }
        let rows = model.rows
        if rows.isEmpty {
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(cast(row), "No keys or passwords yet.")
            gtk_list_box_append(cast(list), row)
        }
        let keyRows = KeyRow.rows(for: rows.map(\.credential))
        for row in rows {
            let r = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(r), 0)
            adw_preferences_row_set_title(cast(r), row.credential.label)
            let used = row.usedBy.isEmpty ? "not used" : "used by " + row.usedBy.joined(separator: ", ")
            let id = row.id
            if let key = keyRows.first(where: { $0.id == id }) {
                adw_action_row_set_subtitle(cast(r), (key.problem ?? "\(key.keyType)  \(key.fingerprint)") + "\n" + used)
                adw_action_row_add_prefix(cast(r), gtk_image_new_from_icon_name("dialog-password-symbolic"))
                if let line = row.publicLine ?? key.publicLine {
                    adw_action_row_add_suffix(cast(r), iconButton("edit-copy-symbolic", tooltip: "Copy Public Key") { [unowned self] in
                        copyToClipboard(line, from: dialog)
                        message("Copied", "The public key is on the clipboard: add it to ~/.ssh/authorized_keys on a server.", parent: dialog)
                    })
                }
                let credentials = rows.map(\.credential)
                adw_action_row_add_suffix(cast(r), iconButton("view-reveal-symbolic", tooltip: "Show Private Key") { [unowned self] in
                    app.reauthenticate(parent: dialog, reason: "Enter the master password to show the private key “\(row.credential.label)”.") { [unowned self] in
                        guard let text = KeyRow.privateText(of: id, in: credentials) else { return }
                        showPrivate(row.credential.label, text)
                    }
                })
            } else {
                adw_action_row_set_subtitle(cast(r), "Password\n" + used)
                adw_action_row_add_prefix(cast(r), gtk_image_new_from_icon_name("dialog-password-symbolic"))
            }
            adw_action_row_add_suffix(cast(r), iconButton("document-edit-symbolic", tooltip: "Rename") { [unowned self] in
                askText("Rename", "", initial: row.credential.label, action: "Rename", parent: dialog) { [unowned self] name in
                    run { [unowned self] in _ = await model.rename(id, to: name) }
                }
            })
            adw_action_row_add_suffix(cast(r), iconButton("user-trash-symbolic", tooltip: "Delete") { [unowned self] in
                alert("Delete “\(row.credential.label)”?", row.usedBy.isEmpty ? "It is removed from the vault on every device."
                        : "It is used by \(row.usedBy.joined(separator: ", ")): change those servers first.",
                      responses: [Response(id: "cancel", label: "Cancel"), Response(id: "delete", label: "Delete", look: .destructive)],
                      parent: dialog) { [unowned self] answer in
                    if answer == "delete" { run { [unowned self] in _ = await model.delete(id) } }
                }
            })
            gtk_list_box_append(cast(list), r)
        }
    }

    private func generate() {
        askText("Generate Key", "An ed25519 key: its public half can be copied to servers.", initial: "you@workstation",
                action: "Generate", parent: dialog) { [unowned self] label in
            run { [unowned self] in _ = await model.generateKey(label: label) }
        }
    }

    private func addPassword() {
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        let name = gtk_entry_new()!
        gtk_entry_set_placeholder_text(cast(name), "Label")
        let secret = passwordEntry(placeholder: "Password")
        gtk_box_append(cast(box), name)
        gtk_box_append(cast(box), secret)
        alert("Add Password", "", responses: [Response(id: "cancel", label: "Cancel"), Response(id: "add", label: "Add", look: .suggested)],
              defaultID: "add", extra: box, parent: dialog) { [unowned self] id in
            let label = entryText(name), password = entryText(secret)
            guard id == "add", !label.isEmpty, !password.isEmpty else { return }
            run { [unowned self] in _ = await model.addPassword(label: label, password: password) }
        }
    }

    private func importFile() {
        pickFile(title: "Import Key", parent: dialog) { [unowned self] path in
            guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            importText(text, suggestedLabel: (path as NSString).lastPathComponent)
        }
    }

    private func importText(_ text: String, suggestedLabel: String) {
        switch model.previewKey(text) {
        case .failure(let error):
            message("Not a Key", error.errorDescription ?? "\(error)", parent: dialog)
        case .success(let preview):
            let label = preview.comment.flatMap { $0.isEmpty ? nil : $0 } ?? suggestedLabel
            guard preview.isEncrypted else {
                return run { [unowned self] in _ = await model.importKey(text, passphrase: nil, label: label) }
            }
            askPassword("Key Passphrase", "This key is protected by a passphrase.", action: "Import", parent: dialog) { [unowned self] pass in
                run { [unowned self] in _ = await model.importKey(text, passphrase: pass, label: label) }
            }
        }
    }

    private func showPrivate(_ name: String, _ text: String) {
        let view = gtk_text_view_new()!
        gtk_text_view_set_editable(cast(view), 0)
        gtk_text_view_set_monospace(cast(view), 1)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(cast(view)), text, -1)
        let s = scrolled(view)
        gtk_scrolled_window_set_min_content_height(cast(s), 220)
        gtk_scrolled_window_set_min_content_width(cast(s), 520)
        alert("Private Key “\(name)”", "Anyone with this text can log in as you. Close it when done.",
              responses: [Response(id: "close", label: "Close"), Response(id: "copy", label: "Copy")],
              extra: s, parent: dialog) { [unowned self] id in
            if id == "copy" { copyToClipboard(text, from: dialog) }
        }
    }
}

// MARK: - File chooser

private final class FilePick {
    let done: (String?) -> Void
    init(_ done: @escaping (String?) -> Void) { self.done = done }
}

/// GtkFileDialog: one existing file; `done` gets its path, nil when cancelled.
func pickFile(title: String, parent: Widget, folder: Bool = false, done: @escaping (String?) -> Void) {
    let chooser = gtk_file_dialog_new()!
    gtk_file_dialog_set_title(chooser, title)
    let box = Unmanaged.passRetained(FilePick(done)).toOpaque()
    let window: UnsafeMutablePointer<GtkWindow>? = gtk_widget_get_root(parent).map { cast($0) }
    let callback: GAsyncReadyCallback = { source, result, data in
        let pick = Unmanaged<FilePick>.fromOpaque(data!).takeRetainedValue()
        var error: UnsafeMutablePointer<GError>?
        let file = gtk_file_dialog_open_finish(OpaquePointer(source), result, &error)
        if let error { g_error_free(error) }
        guard let file else { return pick.done(nil) }
        let path = g_file_get_path(file).map { p -> String in defer { g_free(p) }; return String(cString: p) }
        g_object_unref(file.gptr)
        pick.done(path)
    }
    gtk_file_dialog_open(chooser, window, nil, callback, box)
    g_object_unref(chooser.gptr)
}
