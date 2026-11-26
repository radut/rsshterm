// Preferences: terminal font, light/dark (or follow the system), scrollback, automatic updates.
import CGtk
import Foundation
import RSSHTermLinux

@MainActor
final class PreferencesDialog {
    private let dialog: Widget
    private let parent: Widget
    private var keepAlive: PreferencesDialog?
    private var titles: TabTitlesPage?

    /// Opens on the Tab Titles page.
    func showTabTitles() {
        if let page = titles?.page { adw_preferences_dialog_set_visible_page(cast(dialog), cast(page)) }
    }

    init(app: AppController, parent: Widget) {
        self.parent = parent
        dialog = cast(adw_preferences_dialog_new())
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(cast(page), "General")
        adw_preferences_page_set_icon_name(cast(page), "preferences-system-symbolic")

        let look = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(look), "Terminal")
        adw_preferences_page_add(cast(page), cast(look))

        let fontRow = adw_action_row_new()!
        adw_preferences_row_set_title(cast(fontRow), "Font")
        let fontButton = gtk_font_dialog_button_new(gtk_font_dialog_new())!
        gtk_font_dialog_button_set_level(cast(fontButton), GTK_FONT_LEVEL_FONT)
        let desc = pango_font_description_from_string(app.settings.fontName)
        gtk_font_dialog_button_set_font_desc(cast(fontButton), desc)
        pango_font_description_free(desc)
        gtk_widget_set_valign(fontButton, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(cast(fontRow), fontButton)
        adw_preferences_group_add(cast(look), fontRow)
        onNotify(fontButton, "font-desc") {
            guard let d = gtk_font_dialog_button_get_font_desc(cast(fontButton)), let s = pango_font_description_to_string(d) else { return }
            app.settings.fontName = String(cString: s)
            g_free(s)
            app.settingsChanged()
        }

        let themes = ["Follow System", "Light", "Dark"]
        var cStrings: [UnsafePointer<CChar>?] = themes.map { UnsafePointer(strdup($0)) } + [nil]
        let model = gtk_string_list_new(&cStrings)
        cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) }
        let themeRow = adw_combo_row_new()!
        adw_preferences_row_set_title(cast(themeRow), "Style")
        adw_combo_row_set_model(cast(themeRow), cast(model))
        let schemes = AppSettings.ColorScheme.allCases
        adw_combo_row_set_selected(cast(themeRow), guint(schemes.firstIndex(of: app.settings.colorScheme) ?? 0))
        adw_preferences_group_add(cast(look), themeRow)
        onNotify(themeRow, "selected") {
            let i = Int(adw_combo_row_get_selected(cast(themeRow)))
            guard schemes.indices.contains(i) else { return }
            app.settings.colorScheme = schemes[i]
            app.settingsChanged()
        }

        let scrollRow = adw_spin_row_new_with_range(0, Double(AppSettings.maximumScrollback), 1000)!
        adw_preferences_row_set_title(cast(scrollRow), "Scrollback Lines")
        adw_spin_row_set_value(cast(scrollRow), Double(app.settings.scrollbackLines))
        adw_preferences_group_add(cast(look), scrollRow)
        onNotify(scrollRow, "value") {
            app.settings.scrollbackLines = Int(adw_spin_row_get_value(cast(scrollRow)))
            app.settingsChanged()
        }

        let session = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(session), "Windows")
        adw_preferences_page_add(cast(page), cast(session))
        let restoreRow = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(restoreRow), "Restore Windows and Tabs at Launch")
        adw_action_row_set_subtitle(cast(restoreRow), "Splits, tab titles, SSH sessions and each shell's directory.")
        adw_switch_row_set_active(cast(restoreRow), app.settings.restoreSession ? 1 : 0)
        adw_preferences_group_add(cast(session), restoreRow)
        onNotify(restoreRow, "active") {
            app.settings.restoreSession = adw_switch_row_get_active(cast(restoreRow)) != 0
            app.settingsChanged()
        }

        let indicatorRow = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(indicatorRow), "Striped Background on Receiving Panes")
        adw_action_row_set_subtitle(cast(indicatorRow), "Diagonal red-orange stripes over every pane that receives broadcast input.")
        adw_switch_row_set_active(cast(indicatorRow), app.settings.broadcastIndicator ? 1 : 0)
        adw_preferences_group_add(cast(session), indicatorRow)
        onNotify(indicatorRow, "active") {
            app.settings.broadcastIndicator = adw_switch_row_get_active(cast(indicatorRow)) != 0
            app.settingsChanged()
        }

        let updates = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(updates), "Updates")
        adw_preferences_page_add(cast(page), cast(updates))
        let autoRow = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(autoRow), "Install Updates Automatically")
        adw_action_row_set_subtitle(cast(autoRow), "Checked at launch and once a day.")
        adw_switch_row_set_active(cast(autoRow), app.settings.autoInstallUpdates ? 1 : 0)
        adw_preferences_group_add(cast(updates), autoRow)
        onNotify(autoRow, "active") {
            app.settings.autoInstallUpdates = adw_switch_row_get_active(cast(autoRow)) != 0
            app.settingsChanged()
        }

        adw_preferences_dialog_add(cast(dialog), cast(page))
        titles = TabTitlesPage(app: app)
        adw_preferences_dialog_add(cast(dialog), cast(titles!.page))
        on(dialog, "closed") { [unowned self] in keepAlive = nil }
    }

    func present() {
        keepAlive = self
        adw_dialog_present(cast(dialog), parent)
    }
}
