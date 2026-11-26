// AdwAlertDialog helpers: messages, questions and password prompts.
import CGtk
import Foundation

struct Response {
    enum Look { case normal, suggested, destructive }
    let id: String
    let label: String
    var look: Look = .normal
}

/// Presents an alert over `parent`; `handler` gets the chosen response id ("close" when dismissed).
@discardableResult
func alert(_ heading: String, _ body: String, responses: [Response], defaultID: String? = nil,
           extra: Widget? = nil, parent: Widget, handler: @escaping (String) -> Void = { _ in }) -> Widget {
    let dialog = adw_alert_dialog_new(heading, body)!
    for r in responses {
        adw_alert_dialog_add_response(cast(dialog), r.id, r.label)
        switch r.look {
        case .normal: break
        case .suggested: adw_alert_dialog_set_response_appearance(cast(dialog), r.id, ADW_RESPONSE_SUGGESTED)
        case .destructive: adw_alert_dialog_set_response_appearance(cast(dialog), r.id, ADW_RESPONSE_DESTRUCTIVE)
        }
    }
    if let defaultID { adw_alert_dialog_set_default_response(cast(dialog), defaultID) }
    if let first = responses.first { adw_alert_dialog_set_close_response(cast(dialog), first.id) }
    if let extra { adw_alert_dialog_set_extra_child(cast(dialog), extra) }
    onPointer(dialog, "response") { id in handler(string(id?.assumingMemoryBound(to: CChar.self))) }
    adw_dialog_present(cast(dialog), parent)
    return cast(dialog)
}

func message(_ heading: String, _ body: String, parent: Widget) {
    alert(heading, body, responses: [Response(id: "ok", label: "OK")], parent: parent)
}

/// A GtkPasswordEntry with the peek icon; Enter activates the dialog's default response.
func passwordEntry(placeholder: String) -> Widget {
    let entry = gtk_password_entry_new()!
    gtk_password_entry_set_show_peek_icon(cast(entry), 1)
    gtk_widget_set_tooltip_text(entry, placeholder)
    return entry
}

func entryText(_ entry: Widget) -> String { string(gtk_editable_get_text(cast(entry))) }

/// Asks for a password; `submit` gets it (never on cancel). Enter in the entry submits too.
func askPassword(_ heading: String, _ body: String, action: String, parent: Widget,
                 submit: @escaping (String) -> Void) {
    let entry = passwordEntry(placeholder: "Master password")
    var dialog: Widget?
    on(entry, "activate") {
        guard let d = dialog else { return }
        let text = entryText(entry)
        adw_dialog_close(cast(d))
        submit(text)
    }
    dialog = alert(heading, body, responses: [Response(id: "cancel", label: "Cancel"),
                                              Response(id: "ok", label: action, look: .suggested)],
                   defaultID: "ok", extra: entry, parent: parent) { id in
        if id == "ok" { submit(entryText(entry)) }
    }
    gtk_widget_grab_focus(entry)
}
