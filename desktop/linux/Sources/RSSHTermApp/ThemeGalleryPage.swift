// Preferences › Dark Theme / Light Theme: a live preview, a search field and a Dark / Light / All filter, then
// "Popular" (most used first) and "All" A–Z, each row a swatch in the theme's own colours. Picking applies at once.
import CGtk
import Foundation
import RSSHKit
import RSSHTermLinux

@MainActor
final class ThemeGalleryPage {
    let page: Widget
    private let app: AppController
    private let dark: Bool
    private let preview: Widget
    private let groups: Widget
    private var query = ""
    private var filter: ThemeFilter
    /// Called after a pick, so Preferences can show the new name.
    var onPick: (@MainActor () -> Void)?

    private var selectedID: String { dark ? app.settings.darkThemeID : app.settings.lightThemeID }

    init(app: AppController, dark: Bool) {
        self.app = app
        self.dark = dark
        filter = dark ? .dark : .light

        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for side in [gtk_widget_set_margin_start, gtk_widget_set_margin_end, gtk_widget_set_margin_top,
                     gtk_widget_set_margin_bottom] { side(box, 18) }

        preview = label("")
        gtk_label_set_xalign(cast(preview), 0)
        gtk_widget_add_css_class(preview, "card")
        gtk_box_append(cast(box), preview)

        let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let search = gtk_search_entry_new()!
        gtk_search_entry_set_placeholder_text(cast(search), "Search themes")
        gtk_search_entry_set_search_delay(cast(search), 0)
        gtk_widget_set_hexpand(search, 1)
        gtk_box_append(cast(bar), search)
        var titles: [UnsafePointer<CChar>?] = ThemeFilter.allCases.map { UnsafePointer(strdup($0.rawValue)) } + [nil]
        let show = gtk_drop_down_new_from_strings(&titles)!
        titles.forEach { free(UnsafeMutablePointer(mutating: $0)) }
        gtk_drop_down_set_selected(cast(show), guint(ThemeFilter.allCases.firstIndex(of: filter) ?? 0))
        gtk_widget_set_tooltip_text(show, "Show dark, light or all themes")
        gtk_box_append(cast(bar), show)
        gtk_box_append(cast(box), bar)

        groups = gtk_box_new(GTK_ORIENTATION_VERTICAL, 18)!
        gtk_box_append(cast(box), groups)

        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroll), box)
        gtk_widget_set_vexpand(scroll, 1)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), adw_header_bar_new())
        adw_toolbar_view_set_content(cast(toolbar), scroll)
        page = cast(adw_navigation_page_new(toolbar, dark ? "Dark Theme" : "Light Theme"))

        on(search, "search-changed") { [unowned self] in
            query = string(gtk_editable_get_text(cast(search)))
            rebuild()
        }
        onNotify(show, "selected") { [unowned self] in
            let i = Int(gtk_drop_down_get_selected(cast(show)))
            guard ThemeFilter.allCases.indices.contains(i) else { return }
            filter = ThemeFilter.allCases[i]
            rebuild()
        }
        rebuild()
    }

    private func rebuild() {
        let selected = TerminalColorSchemes.scheme(id: selectedID)
            ?? (dark ? TerminalColorSchemes.defaultDark : TerminalColorSchemes.defaultLight)
        gtk_label_set_markup(cast(preview), ThemeSwatchMarkup.preview(selected))
        while let child = gtk_widget_get_first_child(groups) { gtk_box_remove(cast(groups), child) }
        let sections = TerminalColorSchemes.gallery(query: query, filter: filter)
        if sections.isEmpty {
            gtk_box_append(cast(groups), label("No theme matches “\(query)”.", css: ["dim-label"]))
        }
        for section in sections {
            let group = adw_preferences_group_new()!
            adw_preferences_group_set_title(cast(group), section.title)
            for scheme in section.items { adw_preferences_group_add(cast(group), row(scheme)) }
            gtk_box_append(cast(groups), group)
        }
    }

    private func row(_ scheme: TerminalColorScheme) -> Widget {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(cast(row), ThemeSwatchMarkup.escape(scheme.name))
        adw_action_row_set_subtitle(cast(row), scheme.isDark ? "Dark" : "Light")
        let swatch = label("")
        gtk_label_set_markup(cast(swatch), ThemeSwatchMarkup.swatch(scheme))
        adw_action_row_add_prefix(cast(row), swatch)
        if scheme.id == selectedID {
            let check = gtk_image_new_from_icon_name("object-select-symbolic")!
            adw_action_row_add_suffix(cast(row), check)
        }
        gtk_list_box_row_set_activatable(cast(row), 1)
        let id = scheme.id
        on(row, "activated") { [unowned self] in
            if dark { app.settings.darkThemeID = id } else { app.settings.lightThemeID = id }
            app.settingsChanged()
            rebuild()
            onPick?()
        }
        return row
    }
}
