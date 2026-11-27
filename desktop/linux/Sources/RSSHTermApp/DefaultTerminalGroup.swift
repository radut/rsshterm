// Preferences › Default Terminal: "Make rSshTerm the Default Terminal" for this user (xdg-terminal-exec lists, the
// GNOME terminal key, ssh:// links), with the state and Undo. The system-wide x-terminal-emulator alternative is
// the .deb's (postinst); the row says how to pick it.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHTermLinux

@MainActor
final class DefaultTerminalGroup {
    let group: Widget
    private let row: Widget
    private let makeButton: Widget
    private let undoButton: Widget
    private let terminal: LinuxDefaultTerminal

    init(app: AppController) {
        terminal = LinuxDefaultTerminal(environment: app.environment, home: app.home, runner: FoundationProcessRunner())
        group = cast(adw_preferences_group_new())
        adw_preferences_group_set_title(cast(group), "Default Terminal")
        adw_preferences_group_set_description(cast(group),
            "Files › Open in Terminal, the desktop's terminal key and ssh:// links open rSshTerm. "
            + "For x-terminal-emulator (the system-wide choice): sudo update-alternatives --config x-terminal-emulator")
        row = cast(adw_action_row_new())
        makeButton = button("Make Default", css: ["suggested-action"]) {}
        undoButton = button("Undo", css: ["flat"]) {}
        gtk_widget_set_valign(makeButton, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(undoButton, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(cast(row), undoButton)
        adw_action_row_add_suffix(cast(row), makeButton)
        adw_preferences_group_add(cast(group), row)
        on(makeButton, "clicked") { [unowned self] in
            let t = terminal
            let exe = Self.executable(environment: app.environment)
            run(app) { try await t.makeDefault(executable: exe) }
        }
        on(undoButton, "clicked") { [unowned self] in
            let t = terminal
            run(app) { try await t.undo() }
        }
        refresh()
    }

    /// What the desktop should start: the AppImage when running from one, else the installed rsshterm.
    static func executable(environment: [String: String]) -> String {
        if let image = environment["APPIMAGE"], image.hasPrefix("/") { return image }
        return ShellEnvironment.resolve("rsshterm", path: environment["PATH"]) ?? "/usr/bin/rsshterm"
    }

    private func refresh() {
        let isDefault = terminal.isDefault()
        adw_preferences_row_set_title(cast(row), isDefault ? "rSshTerm is the default terminal" : "rSshTerm is not the default terminal")
        gtk_widget_set_visible(makeButton, isDefault ? 0 : 1)
        gtk_widget_set_visible(undoButton, terminal.canUndo ? 1 : 0)
    }

    private func run(_ app: AppController, _ work: @escaping @Sendable () async throws -> Void) {
        gtk_widget_set_sensitive(row, 0)
        background({ await Result.of { try await work() } }) { [weak self] result in
            guard let self else { return }
            gtk_widget_set_sensitive(row, 1)
            if case .failure(let error) = result { app.activeWindow?.toast("Default terminal: \(error.localizedDescription)") }
            refresh()
        }
    }
}
