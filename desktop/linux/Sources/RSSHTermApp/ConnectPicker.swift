// "How to connect": opening a server with several services (SSH, RDP, VNC, Screen Sharing) shows one large button per
// service, a generic glyph and a label each; Esc cancels.
import CGtk
import Foundation
import RSSHKit

@MainActor
final class ConnectPicker {
    private let dialog: Widget
    private let parent: Widget
    private var keepAlive: ConnectPicker?

    init(server: Server, choices: [ConnectChoice], parent: Widget, done: @escaping (ConnectChoice) -> Void) {
        self.parent = parent
        dialog = cast(adw_dialog_new())
        adw_dialog_set_title(cast(dialog), "Connect to \(server.name)")
        adw_dialog_set_content_width(cast(dialog), 420)

        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
        setMargins(box, 16)
        let hint = label("How do you want to connect?", css: ["dim-label"])
        gtk_widget_set_halign(hint, GTK_ALIGN_START)
        gtk_box_append(cast(box), hint)
        var first: Widget?
        for choice in choices {
            let button = Self.serviceButton(choice.service)
            on(button, "clicked") { [unowned self] in
                adw_dialog_close(cast(dialog))
                done(choice)
            }
            gtk_box_append(cast(box), button)
            first = first ?? button
        }
        let header = adw_header_bar_new()!
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), header)
        adw_toolbar_view_set_content(cast(toolbar), box)
        adw_dialog_set_child(cast(dialog), toolbar)
        if let first { adw_dialog_set_focus(cast(dialog), first) }
        on(dialog, "closed") { [unowned self] in keepAlive = nil }
    }

    /// A wide button: the service's glyph, its name and one line about how it logs in.
    static func serviceButton(_ service: ConnectService) -> Widget {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 14)!
        setMargins(row, 6)
        let icon = gtk_image_new_from_icon_name(service.iconName)!
        gtk_image_set_pixel_size(cast(icon), 32)
        gtk_box_append(cast(row), icon)
        let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        let title = label(service.label, css: ["heading"])
        let detail = label(service.detail, css: ["dim-label", "caption"])
        for l in [title, detail] {
            gtk_widget_set_halign(l, GTK_ALIGN_START)
            gtk_box_append(cast(text), l)
        }
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        gtk_box_append(cast(row), text)
        let button = gtk_button_new()!
        gtk_button_set_child(cast(button), row)
        gtk_widget_add_css_class(button, "connect-choice")
        gtk_widget_set_tooltip_text(button, "Connect with \(service.label)")
        return button
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
    }
}
