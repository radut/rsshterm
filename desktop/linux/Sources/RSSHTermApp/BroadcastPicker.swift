// Ctrl+Shift+Alt+I: choose the panes that get broadcast input. Presets at the top tick a set of panes, the list
// below has every open pane with a checkbox, grouped by window and tab, each row named like its tab (title, then
// user@host · folder · program, the kind icon, "pane N" and "this pane"); the entry filters on any of these. Enter
// starts broadcasting to the ticked panes, Esc cancels.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit

@MainActor
final class BroadcastPicker {
    private let dialog: Widget
    private let entry: Widget
    private let parent: Widget
    private var checks: [(PaneID, Widget, Widget)] = [] // pane, check button, row
    private var headers: [(String, Widget)] = [] // "Window 1 › Tab 2", its header row
    private let rows: [PaneDescription]
    private let done: (Set<PaneID>) -> Void
    private var keepAlive: BroadcastPicker?

    init(presets: [BroadcastPreset], panes: [PaneDescription], checked: Set<PaneID>, parent: Widget,
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
        let windows = Set(panes.map(\.window)).count
        for pane in panes {
            let group = Self.group(pane, windows: windows)
            if headers.last?.0 != group {
                let label = gtk_label_new(group)!
                gtk_widget_set_halign(label, GTK_ALIGN_START)
                for c in ["heading", "dim-label"] { gtk_widget_add_css_class(label, c) }
                for side in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom, gtk_widget_set_margin_start] {
                    side(label, 6)
                }
                let header = gtk_list_box_row_new()!
                gtk_list_box_row_set_child(cast(header), label)
                gtk_list_box_row_set_activatable(cast(header), 0)
                gtk_list_box_row_set_selectable(cast(header), 0)
                gtk_list_box_append(cast(list), header)
                headers.append((group, header))
            }
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(row), 0)
            adw_preferences_row_set_title(cast(row), pane.title)
            adw_action_row_set_subtitle(cast(row), pane.subtitle)
            let check = gtk_check_button_new()!
            gtk_check_button_set_active(cast(check), checked.contains(pane.id) ? 1 : 0)
            adw_action_row_add_prefix(cast(row), check)
            adw_action_row_add_prefix(cast(row), gtk_image_new_from_icon_name(Self.icon(pane.kind)))
            let place = gtk_label_new(pane.isCurrent ? "pane \(pane.pane) · this pane" : "pane \(pane.pane)")!
            gtk_widget_add_css_class(place, pane.isCurrent ? "accent" : "dim-label")
            adw_action_row_add_suffix(cast(row), place)
            adw_action_row_set_activatable_widget(cast(row), check)
            gtk_list_box_append(cast(list), row)
            checks.append((pane.id, check, row))
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

    /// The header a row sits under: "Window 2 › Tab 1", or "Tab 1" with one window.
    static func group(_ pane: PaneDescription, windows: Int) -> String {
        windows > 1 ? "Window \(pane.window) › Tab \(pane.tab)" : "Tab \(pane.tab)"
    }

    static func icon(_ kind: PaneDescription.Kind) -> String {
        switch kind {
        case .localShell: "utilities-terminal-symbolic"
        case .ssh: ConnectService.ssh.iconName
        case .remoteDesktop: ConnectService.rdp.iconName
        }
    }

    private func filter() {
        let words = entryText(entry).split(separator: " ").map(String.init)
        let windows = Set(rows.map(\.window)).count
        var shownGroups: Set<String> = []
        for (i, (_, _, row)) in checks.enumerated() {
            let shown = rows[i].matches(words)
            if shown { shownGroups.insert(Self.group(rows[i], windows: windows)) }
            gtk_widget_set_visible(row, shown ? 1 : 0)
        }
        for (group, header) in headers { gtk_widget_set_visible(header, shownGroups.contains(group) ? 1 : 0) }
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
