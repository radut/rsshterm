// The main menu (header bar ☰) and the application actions behind it. Actions are also reachable over D-Bus
// (org.gtk.Actions), which the smoke test uses to open dialogs.
import CGtk
import Foundation
import RSSHDesktopCore

extension AppController {
    func makeMenu() -> OpaquePointer {
        let menu = g_menu_new()!
        let main = g_menu_new()!
        g_menu_append(main, "New Tab", "app.new-tab")
        g_menu_append(main, "New Window", "app.new-window")
        g_menu_append(main, "Search Hosts…", "app.host-search")
        g_menu_append(main, "Jump To…", "app.jump")
        g_menu_append(main, "Rename Tab…", "app.rename-tab")
        g_menu_append(main, "Quick Connect…", "app.quick-connect")
        g_menu_append(main, "New Remote Desktop…", "app.new-remote-desktop")
        g_menu_append(main, "Servers… (F9)", "app.toggle-sidebar")
        g_menu_append_section(menu, nil, cast(main))

        let moveMenu = g_menu_new()!
        g_menu_append(moveMenu, "Move Pane to New Tab (Ctrl+Shift+Alt+T)", "app.move-pane-to-new-tab")
        g_menu_append(moveMenu, "Move Pane to New Window (Ctrl+Shift+Alt+N)", "app.move-pane-to-new-window")
        g_menu_append(moveMenu, "Move Pane… (Ctrl+Shift+Alt+M)", "app.move-pane-mode")
        g_menu_append(moveMenu, "Move Tab to New Window (Ctrl+Shift+Alt+D)", "app.move-tab-to-new-window")
        g_menu_append(moveMenu, "Merge All Windows", "app.merge-all-windows")
        g_menu_append(moveMenu, "Zoom Pane (Ctrl+Shift+X)", "app.toggle-zoom")
        g_menu_append(moveMenu, "Duplicate Tab", "app.duplicate-tab")
        g_menu_append(moveMenu, "Duplicate Pane", "app.duplicate-pane")
        g_menu_append(moveMenu, "Duplicate Window", "app.duplicate-window")
        g_menu_append(moveMenu, "Edit Window Title…", "app.edit-window-title")
        let moveSection = g_menu_new()!
        g_menu_append_submenu(moveSection, "Window", cast(moveMenu))
        g_menu_append_section(menu, nil, cast(moveSection))

        let broadcastMenu = g_menu_new()!
        g_menu_append(broadcastMenu, "Send Input to Current Session Only", "app.broadcast-current-only")
        g_menu_append(broadcastMenu, "Broadcast to All Panes in All Tabs (Ctrl+Shift+I)", "app.broadcast-all-tabs")
        g_menu_append(broadcastMenu, "Broadcast to All Panes in Current Tab", "app.broadcast-current-tab")
        g_menu_append(broadcastMenu, "Broadcast to Visible Panes", "app.broadcast-visible")
        g_menu_append(broadcastMenu, "Toggle Broadcast to Current Session", "app.broadcast-toggle-session")
        g_menu_append(broadcastMenu, "Choose Panes… (Ctrl+Shift+Alt+I)", "app.broadcast-picker")
        let broadcastSection = g_menu_new()!
        g_menu_append_submenu(broadcastSection, "Broadcast Input", cast(broadcastMenu))
        g_menu_append_section(menu, nil, cast(broadcastSection))

        let vaultMenu = g_menu_new()!
        g_menu_append(vaultMenu, "Keys and Passwords…", "app.keys")
        g_menu_append(vaultMenu, "Import ~/.ssh/config…", "app.import-ssh-config")
        g_menu_append(vaultMenu, "Scan Network…", "app.scan")
        g_menu_append(vaultMenu, "File Manager", "app.files")
        g_menu_append(vaultMenu, "Open File Manager Here", "app.files-here")
        g_menu_append(vaultMenu, "Unlock Vault", "app.unlock")
        g_menu_append(vaultMenu, "Lock Vault", "app.lock")
        if googleConfig != nil { g_menu_append(vaultMenu, "Sign In to Google Drive…", "app.google-sign-in") }
        g_menu_append_section(menu, nil, cast(vaultMenu))

        let tail = g_menu_new()!
        g_menu_append(tail, "Preferences", "app.preferences")
        let help = g_menu_new()!
        g_menu_append(help, "Check for Updates…", "app.check-updates")
        g_menu_append(help, "About rSshTerm", "app.about")
        g_menu_append_submenu(tail, "Help", cast(help))
        g_menu_append(tail, "Quit", "app.quit")
        g_menu_append_section(menu, nil, cast(tail))
        return cast(menu)
    }

    func addActions() {
        let actions: [(String, () -> Void)] = [
            ("new-tab", { [unowned self] in route(.newLocalTab) }),
            ("new-window", { [unowned self] in route(.newLocalWindow) }),
            ("host-search", { [unowned self] in activeWindow?.perform(.hostSearch) }),
            ("jump", { [unowned self] in activeWindow?.perform(.jumpSwitcher) }),
            ("rename-tab", { [unowned self] in activeWindow?.perform(.renameTab) }),
            ("close-pane", { [unowned self] in activeWindow?.perform(.closePane) }),
            ("broadcast-current-only", { [unowned self] in activeWindow?.perform(.broadcastCurrentOnly) }),
            ("broadcast-all-tabs", { [unowned self] in activeWindow?.perform(.broadcastAllTabs) }),
            ("broadcast-current-tab", { [unowned self] in activeWindow?.perform(.broadcastCurrentTab) }),
            ("broadcast-visible", { [unowned self] in activeWindow?.perform(.broadcastVisible) }),
            ("broadcast-toggle-session", { [unowned self] in activeWindow?.perform(.toggleBroadcastSession) }),
            ("broadcast-picker", { [unowned self] in activeWindow?.perform(.broadcastPicker) }),
            ("move-pane-to-new-tab", { [unowned self] in activeWindow?.perform(.movePaneToNewTab) }),
            ("move-pane-to-new-window", { [unowned self] in activeWindow?.perform(.movePaneToNewWindow) }),
            ("move-pane-mode", { [unowned self] in activeWindow?.perform(.movePaneMode) }),
            ("move-tab-to-new-window", { [unowned self] in activeWindow?.perform(.moveTabToNewWindow) }),
            ("merge-all-windows", { [unowned self] in activeWindow?.perform(.mergeAllWindows) }),
            ("toggle-zoom", { [unowned self] in activeWindow?.perform(.toggleZoom) }),
            ("duplicate-tab", { [unowned self] in activeWindow?.perform(.duplicateTab) }),
            ("duplicate-pane", { [unowned self] in activeWindow?.perform(.duplicatePane) }),
            ("duplicate-window", { [unowned self] in activeWindow?.perform(.duplicateWindow) }),
            ("edit-window-title", { [unowned self] in activeWindow?.perform(.editWindowTitle) }),
            ("swap-pane-right", { [unowned self] in activeWindow?.perform(.swapPane(.right)) }),
            ("move-tab-to-first-window", { [unowned self] in
                guard let w = activeWindow, let tab = w.model?.selectedTab, let first = windows.first?.model,
                      first.id != w.model?.id else { return }
                move(tab: tab.id, to: .window(first.id))
            }),
            ("keys", { [unowned self] in showKeys() }),
            ("quick-connect", { [unowned self] in if let w = activeWindow { showQuickConnect(over: w) } }),
            ("toggle-sidebar", { [unowned self] in activeWindow?.toggleSidebar() }),
            ("import-ssh-config", { [unowned self] in showSSHConfigImport() }),
            ("scan", { [unowned self] in showNetworkScan() }),
            ("files", { [unowned self] in showCommander() }),
            ("files-here", { [unowned self] in if let w = activeWindow { openFileManagerHere(from: w) } }),
            ("new-server", { [unowned self] in activeWindow?.newServer() }),
            ("new-remote-desktop", { [unowned self] in activeWindow?.newRemoteDesktop(inGroup: nil) }),
            ("open-last-remote-desktop", { [unowned self] in
                if let d = vault?.remoteDesktops.last { activeWindow?.openRemoteDesktop(d.id, split: false) }
            }),
            ("open-first-remote-desktop", { [unowned self] in
                if let d = vault?.remoteDesktops.first { activeWindow?.openRemoteDesktop(d.id, split: false) }
            }),
            ("unlock", { [unowned self] in
                if let w = activeWindow { bannerAction(from: w) }
            }),
            ("lock", { [unowned self] in lockVault() }),
            ("google-sign-in", { [unowned self] in signInToGoogle() }),
            ("preferences", { [unowned self] in showPreferences() }),
            ("tab-titles", { [unowned self] in showPreferences(tabTitles: true) }),
            ("terminal-theme", { [unowned self] in showPreferences(darkTheme: true) }),
            ("check-updates", { [unowned self] in checkForUpdates(.manual) }),
            ("about", { [unowned self] in showAbout() }),
            ("try-another-login", { [unowned self] in activeWindow?.pickLoginOnFocusedPane() }),
            ("save-login", { [unowned self] in activeWindow?.saveLoginOnFocusedPane() }),
            ("quit", { [unowned self] in quit() }),
        ]
        for (name, run) in actions {
            let action = g_simple_action_new(name, nil)
            onPointer(action, "activate") { _ in run() }
            g_action_map_add_action(cast(gtkApp), cast(action))
            g_object_unref(action.gptr)
        }
        setAccels("app.preferences", ["<Control>comma"])
        setAccels("app.quit", ["<Control><Shift>q"])
        setAccels("app.toggle-sidebar", ["F9"])
    }

    private func setAccels(_ action: String, _ accels: [String]) {
        var list: [UnsafePointer<CChar>?] = accels.map { UnsafePointer(strdup($0)) } + [nil]
        gtk_application_set_accels_for_action(cast(gtkApp), action, &list)
        list.forEach { free(UnsafeMutablePointer(mutating: $0)) }
    }

    func showAbout() {
        guard let parent = activeWindow?.window else { return }
        let about = adw_about_dialog_new()!
        adw_about_dialog_set_application_name(cast(about), "rSshTerm")
        adw_about_dialog_set_version(cast(about), RSSHTermVersion.current)
        adw_about_dialog_set_comments(cast(about), "Local terminal tabs and splits, with your SSH vault built in.")
        adw_about_dialog_set_application_icon(cast(about), "dev.rsshterm.RSSHTerm")
        adw_about_dialog_set_website(cast(about), UpdatePresenter.downloadsURL)
        // About › Legal: the app's line, then every third-party component with its full licence (LegalSections).
        adw_about_dialog_set_copyright(cast(about), LegalSections.appCopyright)
        let isAppImage = ProcessInfo.processInfo.environment["APPIMAGE"] != nil
        adw_about_dialog_set_license_type(cast(about), GTK_LICENSE_CUSTOM)
        adw_about_dialog_set_license(cast(about), LegalSections.appLicense(isAppImage: isAppImage))
        for section in LegalSections.sections() {
            adw_about_dialog_add_legal_section(cast(about), section.title, section.copyright, GTK_LICENSE_CUSTOM,
                                               section.license)
        }
        adw_dialog_present(cast(about), parent)
    }
}

import RSSHTermLinux
