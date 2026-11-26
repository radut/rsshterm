import Foundation

/// The state of a Tab Titles settings page, for any UI (SwiftUI on iOS and macOS, GTK on Linux): the two template
/// fields, their presets and parse problems, the preview of the sample tabs, inserting a placeholder at the cursor
/// and reset. The page binds its controls to these; saving is `settings`.
public struct TabTitleSettingsModel: Equatable, Sendable {
    public enum Field: String, CaseIterable, Sendable, Identifiable {
        case title, subtitle
        public var id: String { rawValue }

        public var name: String { self == .title ? "Title" : "Subtitle" }
        public var help: String {
            self == .title ? "Line 1, bold: the tab's name." : "Line 2, smaller: where you are and what runs."
        }
        public var presets: [TabTitleCatalog.Preset] {
            self == .title ? TabTitleCatalog.titlePresets : TabTitleCatalog.subtitlePresets
        }
        public var defaultTemplate: String {
            self == .title ? TabTitleSettings.defaultTitle : TabTitleSettings.defaultSubtitle
        }
    }

    public struct Preview: Equatable, Sendable, Identifiable {
        public var sample: TabTitleCatalog.Sample
        public var label: TabTitleLabel
        /// What a one-line tab bar shows.
        public var line: String
        public var id: String { sample.id }
    }

    public var settings: TabTitleSettings

    public init(settings: TabTitleSettings = TabTitleSettings()) {
        self.settings = settings
    }

    public func template(for field: Field) -> String {
        field == .title ? settings.title : settings.subtitle
    }

    public mutating func set(_ template: String, for field: Field) {
        switch field {
        case .title: settings.title = template
        case .subtitle: settings.subtitle = template
        }
    }

    /// The parse error to show under the field ("unknown placeholder “hots” (at 9)"); nil when it is fine.
    public func problem(for field: Field) -> String? {
        let problems = settings.problems
        return (field == .title ? problems.title : problems.subtitle)?.description
    }

    public mutating func apply(_ preset: TabTitleCatalog.Preset, to field: Field) {
        set(preset.template, for: field)
    }

    /// The preset the field holds now, nil for a template of the user's own.
    public func selectedPreset(for field: Field) -> TabTitleCatalog.Preset? {
        field.presets.first { $0.template == template(for: field) }
    }

    /// Puts `placeholder`'s token into `field` at `cursor`; returns the cursor after it.
    @discardableResult
    public mutating func insert(_ placeholder: TabTitleCatalog.PlaceholderHelp, into field: Field, at cursor: Int) -> Int {
        let (text, after) = TabTitleCatalog.insert(placeholder.token, into: template(for: field), at: cursor)
        set(text, for: field)
        return after
    }

    public mutating func resetToDefaults() {
        settings = TabTitleSettings()
    }

    /// The sample tabs as the current settings show them.
    public var previews: [Preview] {
        TabTitleCatalog.samples.map { sample in
            let label = settings.label(for: sample.facts)
            return Preview(sample: sample, label: label, line: label.singleLine)
        }
    }
}
