// "Try Another Login": the user (the server's, Quick Connect's users, or another one typed) and the login (a vault
// key the built-in agent holds, or a password ssh asks for in the terminal), then Connect.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit

@MainActor
final class LoginRetryDialog {
    typealias Chosen = @MainActor (String, PaneLoginRetry.Choice) -> Void

    private let server: String
    private let users: [String]
    private let keys: [PaneLoginRetry.KeyOption]
    private let parentWidget: Widget
    private let chosen: Chosen
    private let cancelled: VoidHandler
    private var userIndex = 0
    private var otherUser = ""
    private var loginIndex = 0
    private var dialog: Widget?

    init(server: String, users: [String], keys: [PaneLoginRetry.KeyOption], parent: Widget,
         chosen: @escaping Chosen, cancelled: @escaping VoidHandler) {
        self.server = server
        self.users = users
        self.keys = keys
        self.parentWidget = parent
        self.chosen = chosen
        self.cancelled = cancelled
    }

    // The alert's response handler holds this object (and so the rows' state) until the dialog answers.

    /// The rows under the heading: user, other user (shown for "Other…"), login.
    private func form() -> Widget {
        let list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(list, "boxed-list")
        let other = entryRow("Other User", text: "") { [unowned self] in otherUser = $0 }
        gtk_widget_set_visible(other, 0)
        gtk_list_box_append(cast(list), comboRow("User", titles: users + ["Other…"], selected: 0) { [unowned self] i in
            userIndex = i
            gtk_widget_set_visible(other, i == users.count ? 1 : 0)
        })
        gtk_list_box_append(cast(list), other)
        let logins = keys.map { "Key \($0.label)" } + ["Password (ssh asks in the terminal)"]
        gtk_list_box_append(cast(list), comboRow("Log In With", titles: logins, selected: 0) { [unowned self] i in
            loginIndex = i
        })
        return list
    }

    func present() {
        let body = "Connect to \(server) again with another user, key or password. "
            + "If it works, you can save it for the server."
        dialog = alert("Try Another Login", body, responses: [Response(id: "cancel", label: "Cancel"),
                                                      Response(id: "connect", label: "Connect", look: .suggested)],
              defaultID: "connect", extra: form(), parent: parentWidget) { [self] id in
            guard id == "connect" else { cancelled(); return }
            let user = userIndex < users.count ? users[userIndex] : otherUser
            let choice: PaneLoginRetry.Choice = loginIndex < keys.count ? .key(keys[loginIndex].credentialID) : .askPassword
            chosen(user, choice)
        }
    }

    /// The smoke test's answer (RSSHTERM_TEST_LOGIN_USER): `user` with the first key, as if picked and Connect.
    func answerForTest(user: String) {
        chosen(user, keys.first.map { .key($0.credentialID) } ?? .askPassword)
        if let dialog { adw_dialog_close(cast(dialog)) }
    }
}
