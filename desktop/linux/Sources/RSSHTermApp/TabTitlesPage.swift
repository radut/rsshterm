// Preferences › Tab Titles: the title and subtitle templates (presets, parse problems), one-line mode, a live
// preview of sample tabs, the placeholder reference (Insert puts a token at the cursor of the last field used),
// syntax and where the facts come from, and the shell integration snippets (bash, zsh, fish) to copy.
import CGtk
import Foundation
import RSSHKit
import RSSHTermLinux

@MainActor
final class TabTitlesPage {
    private(set) var page: Widget!
    private var model: TabTitleSettingsModel
    private unowned let app: AppController
    private var entries: [TabTitleSettingsModel.Field: Widget] = [:]
    private var groups: [TabTitleSettingsModel.Field: Widget] = [:]
    private var presetRows: [TabTitleSettingsModel.Field: Widget] = [:]
    private var previewList: Widget!
    private var lastField = TabTitleSettingsModel.Field.title
    private var updating = false

    init(app: AppController) {
        self.app = app
        model = TabTitleSettingsModel(settings: app.settings.tabTitles)
        page = cast(adw_preferences_page_new())
        adw_preferences_page_set_title(cast(page), "Tab Titles")
        adw_preferences_page_set_icon_name(cast(page), "tab-new-symbolic")

        for field in TabTitleSettingsModel.Field.allCases {
            let group = adw_preferences_group_new()!
            adw_preferences_group_set_title(cast(group), field.name)
            adw_preferences_group_set_description(cast(group), field.help)
            adw_preferences_page_add(cast(page), cast(group))
            let presets = field.presets
            let presetRow = comboRow("Preset", titles: presets.map(\.name) + ["Custom"],
                                     selected: presets.firstIndex { $0 == model.selectedPreset(for: field) } ?? presets.count) { [unowned self] i in
                guard !updating, presets.indices.contains(i) else { return }
                model.apply(presets[i], to: field)
                changed(refreshEntries: true)
            }
            adw_preferences_group_add(cast(group), presetRow)
            let entry = adw_entry_row_new()!
            adw_preferences_row_set_title(cast(entry), "Template")
            gtk_editable_set_text(cast(entry), model.template(for: field))
            on(entry, "changed") { [unowned self] in
                guard !updating else { return }
                model.set(string(gtk_editable_get_text(cast(entry))), for: field)
                changed(refreshEntries: false)
            }
            onFocusEnter(entry) { [unowned self] in lastField = field }
            adw_preferences_group_add(cast(group), entry)
            entries[field] = entry
            groups[field] = cast(group)
            presetRows[field] = presetRow
        }

        let options = adw_preferences_group_new()!
        adw_preferences_page_add(cast(page), cast(options))
        let single = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(single), "One Line")
        adw_action_row_set_subtitle(cast(single), "Title and subtitle side by side, for a compact tab bar.")
        adw_switch_row_set_active(cast(single), model.settings.singleLine ? 1 : 0)
        onNotify(single, "active") { [unowned self] in
            model.settings.singleLine = adw_switch_row_get_active(cast(single)) != 0
            changed(refreshEntries: false)
        }
        adw_preferences_group_add(cast(options), single)
        let reset = button("Reset to Defaults", css: ["flat"]) { [unowned self] in
            model.resetToDefaults()
            adw_switch_row_set_active(cast(single), model.settings.singleLine ? 1 : 0)
            changed(refreshEntries: true)
        }
        adw_preferences_group_set_header_suffix(cast(options), reset)

        let preview = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(preview), "Preview")
        adw_preferences_page_add(cast(page), cast(preview))
        previewList = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(previewList), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(previewList, "boxed-list")
        adw_preferences_group_add(cast(preview), previewList)

        let placeholders = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(placeholders), "Placeholders")
        adw_preferences_group_set_description(cast(placeholders), "Insert puts one into the field you edited last, at the cursor.")
        adw_preferences_page_add(cast(page), cast(placeholders))
        for help in TabTitleCatalog.placeholders {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(row), 0)
            adw_preferences_row_set_title(cast(row), help.token)
            adw_action_row_set_subtitle(cast(row), "\(help.summary)  e.g. \(help.example)")
            adw_action_row_add_suffix(cast(row), button("Insert", css: ["flat"]) { [unowned self] in insert(help) })
            adw_preferences_group_add(cast(placeholders), row)
        }

        let syntax = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(syntax), "Syntax")
        adw_preferences_page_add(cast(page), cast(syntax))
        for section in TabTitleCatalog.syntaxHelp + TabTitleCatalog.sourcesHelp {
            let row = adw_action_row_new()!
            adw_preferences_row_set_use_markup(cast(row), 0)
            adw_preferences_row_set_title(cast(row), section.title)
            adw_action_row_set_subtitle(cast(row), section.body)
            adw_preferences_group_add(cast(syntax), row)
        }

        let shell = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(shell), "Shell Integration")
        adw_preferences_group_set_description(cast(shell),
            "Add to a server's shell (or this computer's) so tabs show the folder and the running command.")
        adw_preferences_page_add(cast(page), cast(shell))
        for target in ShellIntegration.titleTargets {
            let expander = adw_expander_row_new()!
            adw_preferences_row_set_title(cast(expander), target.shell)
            adw_expander_row_set_subtitle(cast(expander), "append to \(target.file)")
            let view = gtk_text_view_new()!
            gtk_text_view_set_editable(cast(view), 0)
            gtk_text_view_set_monospace(cast(view), 1)
            gtk_text_view_set_wrap_mode(cast(view), GTK_WRAP_CHAR)
            setMargins(view, 8)
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(cast(view)), target.snippet, -1)
            adw_expander_row_add_row(cast(expander), view)
            let snippet = target.snippet
            adw_expander_row_add_suffix(cast(expander), iconButton("edit-copy-symbolic", tooltip: "Copy") { [unowned self] in
                copyToClipboard(snippet, from: page)
            })
            adw_preferences_group_add(cast(shell), expander)
        }
        renderPreview()
        showProblems()
    }

    private func changed(refreshEntries: Bool) {
        if refreshEntries {
            updating = true
            for (field, entry) in entries { gtk_editable_set_text(cast(entry), model.template(for: field)) }
            updating = false
        }
        updating = true
        for (field, row) in presetRows {
            let presets = field.presets
            adw_combo_row_set_selected(cast(row), guint(presets.firstIndex { $0 == model.selectedPreset(for: field) } ?? presets.count))
        }
        updating = false
        showProblems()
        renderPreview()
        // Templates with a problem are not saved; the tabs keep the last good ones.
        guard model.problem(for: .title) == nil, model.problem(for: .subtitle) == nil else { return }
        app.settings.tabTitles = model.settings
        app.settingsChanged()
    }

    private func showProblems() {
        for field in TabTitleSettingsModel.Field.allCases {
            guard let group = groups[field], let entry = entries[field] else { continue }
            let problem = model.problem(for: field)
            adw_preferences_group_set_description(cast(group), problem.map { "⚠ \($0)" } ?? field.help)
            problem == nil ? gtk_widget_remove_css_class(entry, "error") : gtk_widget_add_css_class(entry, "error")
        }
    }

    private func renderPreview() {
        while let child = gtk_widget_get_first_child(previewList) { gtk_list_box_remove(cast(previewList), child) }
        for preview in model.previews {
            let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
            setMargins(box, 8)
            let tab = gtk_label_new(nil)!
            gtk_label_set_markup(cast(tab), TabLabelMarkup.markup(preview.label, singleLine: model.settings.singleLine))
            gtk_label_set_xalign(cast(tab), 0)
            gtk_box_append(cast(box), tab)
            gtk_box_append(cast(box), label(preview.sample.name, css: ["dim-label", "caption"]))
            gtk_label_set_xalign(cast(gtk_widget_get_last_child(box)), 0)
            gtk_list_box_append(cast(previewList), box)
        }
    }

    private func insert(_ help: TabTitleCatalog.PlaceholderHelp) {
        guard let entry = entries[lastField] else { return }
        let cursor = Int(gtk_editable_get_position(cast(entry)))
        let after = model.insert(help, into: lastField, at: cursor)
        updating = true
        gtk_editable_set_text(cast(entry), model.template(for: lastField))
        updating = false
        gtk_editable_set_position(cast(entry), Int32(after))
        changed(refreshEntries: false)
    }
}
