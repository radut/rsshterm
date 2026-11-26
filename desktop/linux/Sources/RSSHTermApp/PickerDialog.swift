// A search popup: an entry over a list. ↑/↓ move, Enter picks, Shift+Enter picks "alternate" (a split), Esc closes.
// Host search and the jump switcher are both this dialog with their own rows.
import CGtk
import Foundation

struct PickerRow {
    let title: String
    let subtitle: String
    let icon: String
}

@MainActor
final class PickerDialog {
    private let dialog: Widget
    private let entry: Widget
    private let list: Widget
    private let parent: Widget
    private let rowsFor: (String) -> [PickerRow]
    private let pick: (_ index: Int, _ alternate: Bool) -> Void
    private let empty: (String) -> String
    private var rows: [PickerRow] = []
    private var selection = 0
    private var keepAlive: PickerDialog?

    init(title: String, placeholder: String, hint: String, parent: Widget, empty: @escaping (String) -> String,
         rows: @escaping (String) -> [PickerRow], pick: @escaping (_ index: Int, _ alternate: Bool) -> Void) {
        self.parent = parent
        self.rowsFor = rows
        self.pick = pick
        self.empty = empty
        dialog = cast(adw_dialog_new())
        adw_dialog_set_title(cast(dialog), title)
        adw_dialog_set_content_width(cast(dialog), 560)
        adw_dialog_set_content_height(cast(dialog), 440)

        entry = gtk_search_entry_new()
        gtk_search_entry_set_placeholder_text(cast(entry), placeholder)
        gtk_search_entry_set_search_delay(cast(entry), 0)
        list = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_BROWSE)
        gtk_widget_add_css_class(list, "boxed-list")
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(scroller), list)
        gtk_widget_set_vexpand(scroller, 1)
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for side in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom, gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            side(box, 12)
        }
        gtk_box_append(cast(box), entry)
        gtk_box_append(cast(box), scroller)
        gtk_box_append(cast(box), label(hint, css: ["dim-label", "caption"]))
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), adw_header_bar_new())
        adw_toolbar_view_set_content(cast(toolbar), box)
        adw_dialog_set_child(cast(dialog), toolbar)

        on(entry, "search-changed") { [unowned self] in reload() }
        on(entry, "stop-search") { [unowned self] in adw_dialog_close(cast(dialog)) }
        onPointer(list, "row-activated") { [unowned self] row in
            selection = Int(gtk_list_box_row_get_index(cast(row)))
            finish(alternate: false)
        }
        addKeyHandler(entry) { [unowned self] keyval, state in
            switch keyval {
            case 0xff52: move(-1); return true // Up
            case 0xff54: move(1); return true // Down
            case 0xff0d, 0xff8d: finish(alternate: state & 1 != 0); return true // Enter / Shift+Enter
            default: return false
            }
        }
        on(dialog, "closed") { [unowned self] in keepAlive = nil }
        reload()
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
        gtk_widget_grab_focus(entry)
    }

    private func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        selection = ((selection + step) % rows.count + rows.count) % rows.count
        select()
    }

    private func finish(alternate: Bool) {
        guard rows.indices.contains(selection) else { return }
        // Closing emits "closed", which lets this object go: keep what is needed on the stack first.
        let chosen = selection
        let pick = self.pick
        let me = self
        adw_dialog_close(cast(dialog))
        pick(chosen, alternate)
        _ = me
    }

    private func reload() {
        let query = entryText(entry)
        rows = rowsFor(query)
        selection = 0
        while let row = gtk_widget_get_first_child(list) { gtk_list_box_remove(cast(list), row) }
        if rows.isEmpty {
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(cast(row), empty(query))
            gtk_list_box_append(cast(list), row)
            return
        }
        for r in rows {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(row), 0)
            adw_preferences_row_set_title(cast(row), r.title)
            adw_action_row_set_subtitle(cast(row), r.subtitle)
            adw_action_row_add_prefix(cast(row), gtk_image_new_from_icon_name(r.icon))
            gtk_list_box_append(cast(list), row)
        }
        select()
    }

    private func select() {
        guard !rows.isEmpty, let row = gtk_list_box_get_row_at_index(cast(list), Int32(selection)) else { return }
        gtk_list_box_select_row(cast(list), row)
    }
}
