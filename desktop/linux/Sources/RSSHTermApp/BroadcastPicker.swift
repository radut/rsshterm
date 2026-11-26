// Ctrl+Shift+Alt+I: choose the panes that get broadcast input. Presets at the top tick a set of panes, the list
// below has every open pane with a checkbox, the entry filters it; Enter starts broadcasting to the ticked panes,
// Esc cancels.
import CGtk
import Foundation
import RSSHDesktopCore

@MainActor
final class BroadcastPicker {
    private let dialog: Widget
    private let entry: Widget
    private let parent: Widget
    private var checks: [(PaneID, Widget, Widget)] = [] // pane, check button, row
    private let rows: [(PaneID, String, String)]
    private let done: (Set<PaneID>) -> Void
    private var keepAlive: BroadcastPicker?

    init(presets: [BroadcastPreset], panes: [(PaneID, String, String)], checked: Set<PaneID>, parent: Widget,
         done: @escaping (Set<PaneID>) -> Void) {
        self.parent = parent
        self.rows = panes
        self.done = done
        dialog = cast(adw_dialog_new())
        adw_dialog_set_title(cast(dialog), "Broadcast Input To")
        adw_dialog_set_content_width(cast(dialog), 560)
        adw_dialog_set_content_height(cast(dialog), 520)

        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for side in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom, gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            side(box, 12)
        }
        let flow = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(cast(flow), GTK_SELECTION_NONE)
        gtk_flow_box_set_max_children_per_line(cast(flow), 3)
        gtk_box_append(cast(box), flow)

        entry = gtk_search_entry_new()
        gtk_search_entry_set_placeholder_text(cast(entry), "Filter panes")
        gtk_search_entry_set_search_delay(cast(entry), 0)
        gtk_box_append(cast(box), entry)

        let list = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(cast(list), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(list, "boxed-list")
        for (id, title, subtitle) in panes {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(row), 0)
            adw_preferences_row_set_title(cast(row), title)
            adw_action_row_set_subtitle(cast(row), subtitle)
            let check = gtk_check_button_new()!
            gtk_check_button_set_active(cast(check), checked.contains(id) ? 1 : 0)
            adw_action_row_add_prefix(cast(row), check)
            adw_action_row_set_activatable_widget(cast(row), check)
            gtk_list_box_append(cast(list), row)
            checks.append((id, check, row))
        }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(cast(scroller), list)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(cast(box), scroller)

        for preset in presets {
            let ids = Set(preset.panes)
            let button = gtk_button_new_with_label(preset.name)!
            gtk_widget_add_css_class(button, "pill")
            on(button, "clicked") { [unowned self] in
                for (id, check, _) in checks { gtk_check_button_set_active(cast(check), ids.contains(id) ? 1 : 0) }
            }
            gtk_flow_box_append(cast(flow), button)
        }

        let start = gtk_button_new_with_label("Broadcast")!
        gtk_widget_add_css_class(start, "suggested-action")
        on(start, "clicked") { [unowned self] in finish() }
        let header = adw_header_bar_new()!
        adw_header_bar_pack_end(cast(header), start)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), header)
        adw_toolbar_view_set_content(cast(toolbar), box)
        adw_dialog_set_child(cast(dialog), toolbar)

        on(entry, "search-changed") { [unowned self] in filter() }
        on(entry, "activate") { [unowned self] in finish() }
        on(entry, "stop-search") { [unowned self] in adw_dialog_close(cast(dialog)) }
        on(dialog, "closed") { [unowned self] in keepAlive = nil }
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
        gtk_widget_grab_focus(entry)
    }

    private func filter() {
        let words = entryText(entry).lowercased().split(separator: " ")
        for (i, (_, _, row)) in checks.enumerated() {
            let text = "\(rows[i].1) \(rows[i].2)".lowercased()
            gtk_widget_set_visible(row, words.allSatisfy { text.contains($0) } ? 1 : 0)
        }
    }

    private func finish() {
        let chosen = Set(checks.filter { gtk_check_button_get_active(cast($0.1)) != 0 }.map(\.0))
        let done = self.done
        let me = self
        adw_dialog_close(cast(dialog))
        done(chosen)
        _ = me
    }
}
