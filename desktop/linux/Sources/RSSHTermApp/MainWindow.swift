// One application window: AdwTabView tabs, each tab a GtkPaned tree built from the core layout model (Window →
// Tab → SplitNode). Every change goes through `setModel`: new panes spawn, gone panes end, changed tabs rebuild.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

@MainActor
final class MainWindow {
    unowned let app: AppController
    let window: Widget
    let tabView: OpaquePointer
    private let banner: Widget
    private let toasts: Widget
    private let tabStrip: Widget
    /// The labels last shown, for the test state and the window title.
    private(set) var tabLabels: [TabTitleLabel] = []
    /// Sidebar | tabs.
    private let split: Widget
    private var sidebar: ServerSidebar?
    private(set) var model: Window?
    private var panes: [PaneID: TerminalPane] = [:]
    /// "Try another login…" state of ssh panes whose login was refused (MainWindow+LoginRetry).
    var loginRetries: [PaneID: PaneLoginRetry] = [:]
    /// Remote desktop panes (no terminal).
    private var screens: [PaneID: ScreenPane] = [:]
    private var pages: [UUID: (page: OpaquePointer, holder: Widget)] = [:]
    private var closingPages: Set<UnsafeMutableRawPointer> = []
    private var syncing = false

    init(app: AppController, gtkApp: OpaquePointer, restoring: Window? = nil) {
        self.app = app
        window = adw_application_window_new(cast(gtkApp))
        gtk_window_set_title(cast(window), "rSshTerm")
        gtk_window_set_default_size(cast(window), 1100, 700)

        tabView = adw_tab_view_new()
        // Our keybindings own Ctrl+Tab, Ctrl+PageUp/Down and the number keys.
        adw_tab_view_set_shortcuts(tabView, ADW_TAB_VIEW_SHORTCUT_NONE)
        // Our own tab strip: AdwTabBar shows one line; tabs here have a bold title and a smaller subtitle.
        tabStrip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
        gtk_widget_add_css_class(tabStrip, "tab-strip")
        let stripScroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(stripScroll), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_child(cast(stripScroll), tabStrip)
        setMargins(stripScroll, 2)

        banner = adw_banner_new("")
        let header = adw_header_bar_new()!
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), header)
        adw_toolbar_view_add_top_bar(cast(toolbar), banner)
        adw_toolbar_view_add_top_bar(cast(toolbar), stripScroll)
        split = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)
        gtk_paned_set_end_child(cast(split), cast(tabView))
        gtk_paned_set_shrink_start_child(cast(split), 0)
        gtk_paned_set_resize_start_child(cast(split), 0)
        adw_toolbar_view_set_content(cast(toolbar), split)
        toasts = adw_toast_overlay_new()
        adw_toast_overlay_set_child(cast(toasts), toolbar)
        adw_application_window_set_content(cast(window), toasts)

        adw_header_bar_pack_start(cast(header), iconButton("list-add-symbolic", tooltip: "New Tab (Ctrl+Shift+T)") { [unowned self] in
            perform(.newTab)
        })
        adw_header_bar_pack_start(cast(header), iconButton("sidebar-show-symbolic", tooltip: "Servers… (F9)") { [unowned self] in
            toggleSidebar()
        })
        adw_header_bar_pack_start(cast(header), iconButton("system-search-symbolic", tooltip: "Search Hosts (Ctrl+Shift+K)") { [unowned self] in
            perform(.hostSearch)
        })
        let menu = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(menu), "open-menu-symbolic")
        gtk_menu_button_set_menu_model(cast(menu), cast(app.menuModel))
        gtk_menu_button_set_primary(cast(menu), 1)
        gtk_widget_set_tooltip_text(menu, "Main Menu")
        adw_header_bar_pack_end(cast(header), menu)

        on(banner, "button-clicked") { [unowned self] in self.app.bannerAction(from: self) }
        onPointerBool(tabView, "close-page") { [unowned self] page in closePageRequested(OpaquePointer(page!)) }
        onNotify(tabView, "selected-page") { [unowned self] in selectedPageChanged() }
        let tabMenu = g_menu_new()!
        g_menu_append(tabMenu, "Rename Tab…", "app.rename-tab")
        g_menu_append(tabMenu, "Close Tab", "app.close-pane")
        adw_tab_view_set_menu_model(tabView, cast(tabMenu))
        onPointer(tabView, "setup-menu") { [unowned self] page in
            if let page { adw_tab_view_set_selected_page(tabView, OpaquePointer(page)) }
        }
        on(window, "destroy") { [unowned self] in
            // The tab view goes with the window: only end the terminals.
            model = nil
            pages.removeAll()
            panes.removeAll()
            screens.values.forEach { $0.stop() }
            screens.removeAll()
            self.app.windowClosed(self, emptied: false)
        }
        addKeyHandler(window) { [unowned self] keyval, state in handleKey(keyval: keyval, state: state) }

        setModel(restoring ?? Window(tabs: [Tab(pane: newLocalPane())]))
        updateBanner()
    }

    func present() { gtk_window_present(cast(window)) }

    var focusedPane: TerminalPane? { model.flatMap { panes[$0.selectedTab.focused] } }
    var focusedContent: PaneContent? { model?.selectedTab.focusedPane.content }

    // MARK: Server sidebar

    /// The vault opened: the sidebar can show its servers.
    func attachServerList() {
        guard sidebar == nil, let list = app.serverList else { return }
        let s = ServerSidebar(model: list, window: self)
        sidebar = s
        gtk_paned_set_start_child(cast(split), s.widget)
        gtk_paned_set_position(cast(split), 280)
        gtk_widget_set_visible(s.widget, app.sidebarShown ? 1 : 0)
    }

    func newServer() { sidebar?.newServer(inGroup: nil) }

    /// A tab running `argv` (Quick Connect).
    func openCommand(_ argv: [String], title: String) {
        guard let model else { return }
        setModel(model.addingTab(Tab(title: title, pane: Pane(content: .localShell(command: argv)))))
    }

    func detachServerList() {
        sidebar = nil
        gtk_paned_set_start_child(cast(split), nil)
    }

    /// F9 / Servers…: the servers sidebar (the vault opens first when it is locked).
    func toggleSidebar() {
        guard let sidebar else { return app.whenVaultOpens { [weak self] in self?.setSidebar(visible: true) } }
        setSidebar(visible: gtk_widget_get_visible(sidebar.widget) == 0)
    }

    func setSidebar(visible: Bool) {
        guard let sidebar else { return }
        gtk_widget_set_visible(sidebar.widget, visible ? 1 : 0)
        app.sidebarShown = visible
        present()
    }

    /// A new tab running `content` (a server, a command, a shell in a folder).
    func openTab(_ content: PaneContent, title: String? = nil) {
        guard let model else { return }
        setModel(model.addingTab(Tab(title: title, pane: Pane(content: content))))
    }

    var sidebarWidget: Widget? { sidebar?.widget }
    var allPanes: [TerminalPane] { Array(panes.values) }

    func newLocalPane() -> Pane { Pane(content: .localShell()) }

    // MARK: Actions

    func perform(_ action: DesktopAction) {
        guard let model else { return }
        switch action {
        case .hostSearch, .commandPalette: app.showHostSearch(over: self)
        case .newWindow: app.route(.newLocalWindow)
        case .jumpSwitcher: app.showJumpSwitcher(over: self)
        case .renameTab: renameSelectedTab()
        case .broadcastCurrentOnly, .broadcastAllTabs, .broadcastCurrentTab, .broadcastVisible, .toggleBroadcastSession:
            app.applyBroadcast(action, focused: model.selectedTab.focused)
            focusedPane?.grabFocus()
        case .broadcastPicker: app.showBroadcastPicker(over: self)
        default: setModel(model.applying(action, newPane: newLocalPane))
        }
    }

    /// Jump switcher: select the pane's tab, focus it and bring this window up.
    func jump(to id: PaneID) {
        guard let model, let index = model.tabs.firstIndex(where: { $0.paneIDs.contains(id) }) else { return }
        var next = model
        while next.selectedIndex != index { next = next.selectingNextTab() }
        setModel(next.updatingSelectedTab { $0.focusing(id) })
        present()
    }

    /// Ctrl+Shift+R: the tab's title, prefilled; Enter saves, empty brings the automatic title back.
    func renameSelectedTab() {
        guard let model else { return }
        let tab = model.selectedTab
        let entry = gtk_entry_new()!
        gtk_editable_set_text(cast(entry), tab.title ?? panes[tab.focused]?.title ?? "")
        gtk_entry_set_placeholder_text(cast(entry), "Automatic title")
        gtk_entry_set_activates_default(cast(entry), 1)
        let tabID = tab.id
        alert("Rename Tab", "Leave it empty to use the title the shell or host sets.",
              responses: [Response(id: "cancel", label: "Cancel"), Response(id: "rename", label: "Rename", look: .suggested)],
              defaultID: "rename", extra: entry, parent: window) { [weak self] id in
            guard id == "rename", let self, let current = self.model,
                  let i = current.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let text = entryText(entry).trimmingCharacters(in: .whitespaces)
            var tabs = current.tabs
            tabs[i] = tabs[i].renamed(text.isEmpty ? nil : text)
            self.setModel(Window(id: current.id, tabs: tabs, selectedIndex: current.selectedIndex,
                                 broadcastsInput: current.broadcastsInput))
        }
        gtk_widget_grab_focus(entry)
    }

    /// Host search Enter / Shift+Enter: the server in a new tab or in a split of the focused pane.
    /// Opens the server's terminal, or its first screen when SSH is off (`Vault.opening`).
    /// Opens a server: with several services (SSH, RDP, VNC, Screen Sharing) it asks how first ("How to connect");
    /// with one it opens that.
    func openServer(_ id: UUID, split: Bool) {
        guard let vault = app.vault, let server = vault.servers.first(where: { $0.id == id }) else {
            return openSSH(id, split: split)
        }
        let choices = vault.connectChoices(for: server)
        guard choices.count > 1 else { return open(vault.opening(server), server: id, split: split) }
        ConnectPicker(server: server, choices: choices, parent: window) { [weak self] choice in
            self?.open(choice.opening, server: id, split: split)
        }.present()
    }

    private func open(_ opening: ServerOpening, server id: UUID, split: Bool) {
        switch opening {
        case .ssh: openSSH(id, split: split)
        case .screen(let screen): openRemoteDesktop(screen, split: split)
        }
    }

    /// The server's SSH terminal, without asking.
    func openSSH(_ id: UUID, split: Bool) {
        guard let model else { return }
        let pane = Pane(content: .ssh(serverID: id))
        setModel(split ? model.updatingSelectedTab { $0.splitting(.right, with: pane) } : model.addingTab(Tab(pane: pane)))
    }

    private func handleKey(keyval: UInt32, state: UInt32) -> Bool {
        if screenHasKeys { return false }
        let mods = GdkModifiers(state: state)
        if let clip = KeyTranslator.clipboard(keyval: keyval, modifiers: mods) {
            clip == .copy ? focusedPane?.copy() : pasteClipboard()
            return true
        }
        guard let chord = KeyTranslator.chord(keyval: keyval, modifiers: mods),
              let action = app.keybindings.action(for: chord) else { return false }
        perform(action)
        return true
    }

    /// Typed input of `source` also goes to the panes the app's broadcast state names (any window).
    private func broadcast(from source: PaneID, _ text: String) {
        for target in app.broadcastTargets(from: source).dropFirst() { app.pane(target)?.send(text) }
    }

    /// The panes on screen: the selected tab's (only the zoomed one while zoomed).
    var visiblePanes: Set<PaneID> { model.map { Set($0.selectedTab.visibleFrames.keys) } ?? [] }

    func pane(_ id: PaneID) -> TerminalPane? { panes[id] }

    /// Badges and stripes from the broadcast state.
    func updateBroadcastIndicators() {
        guard let model else { return }
        let focused = app.activeWindow === self ? model.selectedTab.focused : app.focusedPaneID
        for (id, pane) in panes {
            pane.setReceiving(app.isReceiving(id, focused: focused), source: id == focused,
                              indicator: app.settings.broadcastIndicator)
        }
        updateTitles()
    }

    func pasteClipboard() {
        guard let focused = focusedPane else { return }
        let targets = app.broadcastTargets(from: focused.id)
        guard targets.count > 1 else { return focused.paste() }
        app.readClipboard(from: window) { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            let send = { for id in targets { self.app.pane(id)?.paste(text) } }
            guard PastePolicy.needsConfirmation(text) else { return send() }
            alert("Paste into \(targets.count) Panes?",
                  "The text has line breaks or control characters; it may run as commands in every pane that receives the broadcast.",
                  responses: [Response(id: "cancel", label: "Cancel"), Response(id: "paste", label: "Paste", look: .destructive)],
                  parent: window) { id in if id == "paste" { send() } }
        }
    }

    // MARK: Model → widgets

    func toast(_ text: String) {
        adw_toast_overlay_add_toast(cast(toasts), adw_toast_new(text))
    }

    func setModel(_ new: Window?) {
        let old = model
        let diff = PaneDiff(from: old, to: new)
        model = new
        for pane in diff.added {
            if case .remoteDesktop(let desktopID) = pane.content {
                screens[pane.id] = makeScreen(pane, desktopID: desktopID)
            } else {
                panes[pane.id] = makePane(pane)
            }
        }
        syncing = true
        defer { syncing = false }

        let liveTabs = Set(new?.tabs.map(\.id) ?? [])
        for (tabID, entry) in pages where !liveTabs.contains(tabID) {
            pages[tabID] = nil
            closingPages.insert(UnsafeMutableRawPointer(entry.page))
            adw_tab_view_close_page(tabView, entry.page)
        }
        let oldTabs = Dictionary((old?.tabs ?? []).map { ($0.id, $0) }) { a, _ in a }
        for (index, tab) in (new?.tabs ?? []).enumerated() {
            if pages[tab.id] == nil {
                let holder = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
                let page = adw_tab_view_insert(tabView, holder, Int32(index))!
                pages[tab.id] = (page, holder)
            }
            let entry = pages[tab.id]!
            adw_tab_view_reorder_page(tabView, entry.page, Int32(index))
            let before = oldTabs[tab.id]
            if before == nil || before!.root != tab.root || before!.zoomed != tab.zoomed {
                rebuild(tab, in: entry.holder)
            }
        }
        for id in diff.removed {
            panes[id] = nil
            loginRetries[id] = nil
            screens[id]?.stop()
            screens[id] = nil
        }
        guard let new else {
            app.windowClosed(self, emptied: true)
            gtk_window_destroy(cast(window))
            return
        }
        if let selected = pages[new.selectedTab.id] { adw_tab_view_set_selected_page(tabView, selected.page) }
        updateTitles()
        app.layoutChanged()
        let focus = new.selectedTab.focused
        onMain { [weak self] in
            self?.panes[focus]?.grabFocus()
            self?.screens[focus]?.grabFocus()
        }
        app.stateChanged()
    }

    private func paneTitle(_ id: PaneID) -> String? { panes[id]?.title ?? screens[id]?.title }

    private func makeScreen(_ pane: Pane, desktopID: UUID) -> ScreenPane {
        let screen = ScreenPane(id: pane.id, desktopID: desktopID, window: self)
        let id = pane.id
        screen.onTitle = { [weak self] in self?.updateTitles() }
        screen.onFocus = { [weak self] in self?.paneFocused(id) }
        return screen
    }

    /// A remote desktop in a new tab, or in a split of the focused pane.
    func openRemoteDesktop(_ id: UUID, split: Bool) {
        guard let model else { return }
        let pane = Pane(content: .remoteDesktop(id: id))
        setModel(split ? model.updatingSelectedTab { $0.splitting(.right, with: pane) } : model.addingTab(Tab(pane: pane)))
    }

    func editRemoteDesktop(_ id: UUID) {
        guard let desktop = app.vault?.remoteDesktops.first(where: { $0.id == id }) else { return }
        RemoteDesktopEditorDialog(desktop: desktop, app: app, parent: window).present()
    }

    func newRemoteDesktop(inGroup groupID: UUID?) {
        guard app.vault != nil else { return toast("Unlock the vault first.") }
        RemoteDesktopEditorDialog(desktop: nil, groupID: groupID, app: app, parent: window).present()
    }

    /// True when `id` is the focused pane of the selected tab of the active window.
    func isFocusedPane(_ id: PaneID) -> Bool {
        model?.selectedTab.focused == id && app.activeWindow === self
    }

    /// A focused screen that holds the keyboard gets every key (the window's shortcuts wait until Ctrl+Alt).
    var screenHasKeys: Bool { model.flatMap { screens[$0.selectedTab.focused] }?.isGrabbingKeys ?? false }

    private func makePane(_ pane: Pane) -> TerminalPane {
        let host: String? = if case .ssh(let id) = pane.content { app.vault?.servers.first { $0.id == id }?.host } else { nil }
        // SSH panes restored before the vault opens wait for it (`spawnPending`).
        let waits: Bool = if case .ssh = pane.content { app.vault == nil } else { false }
        let server: Server? = if case .ssh(let id) = pane.content { app.vault?.servers.first { $0.id == id } } else { nil }
        let t = TerminalPane(id: pane.id, plan: waits ? nil : app.spawnPlan(for: pane.content), host: host,
                             settings: app.settings, dark: app.isDark, server: server)
        let id = pane.id
        t.onExit = { [weak self] _ in self?.paneExited(id) }
        t.onRefusedLogin = { [weak self] in self?.loginRefused(id) }
        t.onTitle = { [weak self] in self?.updateTitles() }
        t.onFocus = { [weak self] in self?.paneFocused(id) }
        t.onCommit = { [weak self] text in self?.broadcast(from: id, text) }
        t.onBadgeClicked = { [weak self] in self?.app.stopBroadcast(to: id) }
        t.onContextMenu = { [weak self, weak t] x, y in
            guard let self, let t else { return }
            contextMenu(on: t.widget, x: x, y: y, items: [
                ("Copy", { t.copy() }),
                ("Paste", { [weak self] in self?.pasteClipboard() }),
                ("Open File Manager Here", { [weak self] in
                    guard let self else { return }
                    paneFocused(id)
                    app.openFileManagerHere(from: self)
                }),
                ("Split Right", { [weak self] in self?.perform(.splitRight) }),
                ("Split Down", { [weak self] in self?.perform(.splitDown) }),
                ("Rename Tab…", { [weak self] in self?.perform(.renameTab) }),
            ])
        }
        return t
    }

    /// The vault opened: start the SSH panes that were waiting for it.
    func spawnPending() {
        for screen in screens.values where screen.waitingForVault { screen.start() }
        guard let model else { return }
        for pane in model.tabs.flatMap(\.panes) {
            guard let t = panes[pane.id], !t.started else { continue }
            t.start(app.spawnPlan(for: pane.content))
        }
    }

    /// Working directories the local shells reported (OSC 7), for session restore.
    var directories: [PaneID: String] {
        var out: [PaneID: String] = [:]
        for (id, pane) in panes { if let d = pane.directory { out[id] = d } }
        return out
    }

    private func paneExited(_ id: PaneID) {
        guard let model, let tabIndex = model.tabs.firstIndex(where: { $0.paneIDs.contains(id) }) else { return }
        let tab = model.tabs[tabIndex]
        if let remaining = tab.closing(id) {
            var tabs = model.tabs
            tabs[tabIndex] = remaining
            setModel(Window(id: model.id, tabs: tabs, selectedIndex: model.selectedIndex,
                            broadcastsInput: model.broadcastsInput))
        } else {
            setModel(model.closingTab(at: tabIndex))
        }
    }

    private func paneFocused(_ id: PaneID) {
        guard !syncing, let model, model.selectedTab.paneIDs.contains(id), model.selectedTab.focused != id else { return }
        self.model = model.updatingSelectedTab { $0.focusing(id) }
        app.layoutChanged()
        app.stateChanged()
    }

    /// The tab's widgets from its split tree: GtkPaned per split, the terminals as leaves (zoomed: one terminal).
    private func rebuild(_ tab: Tab, in holder: Widget) {
        while let child = gtk_widget_get_first_child(holder) { gtk_box_remove(cast(holder), child) }
        let root: SplitNode = tab.zoomed.flatMap { z in tab.panes.first { $0.id == z } }.map { .pane($0) } ?? tab.root
        gtk_box_append(cast(holder), build(root))
    }

    private func build(_ node: SplitNode) -> Widget {
        switch node {
        case .pane(let pane):
            let w = panes[pane.id]?.container ?? screens[pane.id]!.widget!
            detach(w)
            return w
        case .split(let axis, let ratio, let first, let second):
            let horizontal = axis == .horizontal
            let paned = gtk_paned_new(horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL)!
            gtk_paned_set_wide_handle(cast(paned), 1)
            gtk_paned_set_shrink_start_child(cast(paned), 0)
            gtk_paned_set_shrink_end_child(cast(paned), 0)
            gtk_paned_set_start_child(cast(paned), build(first))
            gtk_paned_set_end_child(cast(paned), build(second))
            var placed = false
            onNotify(paned, "max-position") {
                guard !placed else { return }
                let size = horizontal ? gtk_widget_get_width(paned) : gtk_widget_get_height(paned)
                guard size > 0 else { return }
                placed = true
                gtk_paned_set_position(cast(paned), Int32(Double(size) * ratio))
            }
            return paned
        }
    }

    /// Takes a terminal out of its old GtkPaned or box (we hold our own reference, so it survives).
    private func detach(_ widget: Widget) {
        guard let parent = gtk_widget_get_parent(widget) else { return }
        if isA(parent, gtk_paned_get_type()) {
            if gtk_paned_get_start_child(cast(parent)) == widget { gtk_paned_set_start_child(cast(parent), nil) }
            if gtk_paned_get_end_child(cast(parent)) == widget { gtk_paned_set_end_child(cast(parent), nil) }
        } else if isA(parent, gtk_box_get_type()) {
            gtk_box_remove(cast(parent), widget)
        } else {
            gtk_widget_unparent(widget)
        }
    }

    /// Every pane's live title facts.
    var titleStates: [PaneID: PaneTitleState] {
        panes.mapValues(\.titleState)
    }

    /// Tab labels from the title templates (Settings › Tab Titles); the window title is the selected one's two lines.
    func updateTitles() {
        guard let model else { return }
        let context = app.titleContext
        let states = titleStates
        tabLabels = model.tabs.enumerated().map { i, tab in context.label(for: tab, index: i + 1, states: states) }
        for (tab, label) in zip(model.tabs, tabLabels) {
            guard let entry = pages[tab.id] else { continue }
            adw_tab_page_set_title(entry.page, label.singleLine)
            adw_tab_page_set_tooltip(entry.page, label.windowTitle)
        }
        let selected = tabLabels.indices.contains(model.selectedIndex) ? tabLabels[model.selectedIndex].windowTitle : ""
        let broadcasting = app.broadcast.mode == .currentOnly ? "" : "broadcasting input — "
        gtk_window_set_title(cast(window), (selected.isEmpty ? "" : selected + " — ") + broadcasting + "rSshTerm")
        rebuildTabStrip()
    }

    private func rebuildTabStrip() {
        guard let model else { return }
        while let child = gtk_widget_get_first_child(tabStrip) { gtk_box_remove(cast(tabStrip), child) }
        let single = app.settings.tabTitles.singleLine
        for (index, tab) in model.tabs.enumerated() {
            let label = tabLabels.indices.contains(index) ? tabLabels[index] : TabTitleLabel(title: "Terminal", subtitle: "")
            let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
            let text = gtk_label_new(nil)!
            gtk_label_set_markup(cast(text), TabLabelMarkup.markup(label, singleLine: single) + (tab.panes.count > 1 ? " <small>(\(tab.panes.count))</small>" : ""))
            gtk_label_set_xalign(cast(text), 0)
            gtk_label_set_ellipsize(cast(text), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(cast(text), 32)
            gtk_widget_set_hexpand(text, 1)
            gtk_box_append(cast(box), text)
            let tabID = tab.id
            let close = iconButton("window-close-symbolic", tooltip: "Close Tab") { [unowned self] in closeTab(tabID) }
            gtk_widget_add_css_class(close, "flat")
            gtk_widget_add_css_class(close, "circular")
            gtk_widget_set_valign(close, GTK_ALIGN_CENTER)
            gtk_box_append(cast(box), close)
            let item = gtk_button_new()!
            gtk_button_set_child(cast(item), box)
            gtk_widget_add_css_class(item, "flat")
            gtk_widget_add_css_class(item, "tab-item")
            if index == model.selectedIndex { gtk_widget_add_css_class(item, "selected-tab") }
            gtk_widget_set_tooltip_text(item, label.windowTitle)
            gtk_widget_set_size_request(item, 180, -1)
            on(item, "clicked") { [unowned self] in selectTab(tabID) }
            onRightClick(item) { [unowned self] x, y in
                selectTab(tabID)
                contextMenu(on: item, x: x, y: y, items: [
                    ("Rename Tab…", { [unowned self] in perform(.renameTab) }),
                    ("Close Tab", { [unowned self] in closeTab(tabID) }),
                ])
            }
            // Drag a tab onto another to put it there.
            let drag = gtk_drag_source_new()!
            gtk_drag_source_set_actions(drag, GDK_ACTION_MOVE)
            onDragPrepare(drag) { _, _ in textContent("rsshterm-tab:" + tabID.uuidString) }
            gtk_widget_add_controller(item, cast(drag))
            let drop = gtk_drop_target_new(gTypeString, GDK_ACTION_MOVE)!
            onDrop(drop) { [unowned self] value, _, _ in
                guard let value, let raw = g_value_get_string(value) else { return false }
                let text = String(cString: raw)
                guard text.hasPrefix("rsshterm-tab:"), let dragged = UUID(uuidString: String(text.dropFirst(13))) else { return false }
                moveTab(dragged, onto: tabID)
                return true
            }
            gtk_widget_add_controller(item, cast(drop))
            gtk_box_append(cast(tabStrip), item)
        }
    }

    private func moveTab(_ dragged: UUID, onto target: UUID) {
        guard let model, let from = model.tabs.firstIndex(where: { $0.id == dragged }),
              let onto = model.tabs.firstIndex(where: { $0.id == target }),
              let to = TabReorder.destination(from: from, onto: onto, count: model.tabs.count) else { return }
        onMain { [weak self] in self?.setModel(model.movingTab(from: from, to: to)) }
    }

    private func selectTab(_ id: UUID) {
        guard let model, let index = model.tabs.firstIndex(where: { $0.id == id }), index != model.selectedIndex else { return }
        var next = model
        while next.selectedIndex != index { next = next.selectingNextTab() }
        setModel(next)
    }

    private func closeTab(_ id: UUID) {
        guard let model, let index = model.tabs.firstIndex(where: { $0.id == id }) else { return }
        setModel(model.closingTab(at: index))
    }

    /// Polls the foreground job of the visible local panes; relabels when one changed.
    func pollTitles(user: String?, host: String?, home: String?) {
        guard let model else { return }
        var changed = false
        for id in model.selectedTab.paneIDs {
            if panes[id]?.pollForeground(user: user, host: host, home: home) == true { changed = true }
        }
        if changed { updateTitles() }
    }

    // MARK: Tab view signals

    private func closePageRequested(_ page: OpaquePointer) -> Bool {
        if closingPages.remove(UnsafeMutableRawPointer(page)) != nil {
            adw_tab_view_close_page_finish(tabView, page, 1)
            return true
        }
        // The user clicked a tab's close button.
        guard let model, let (tabID, _) = pages.first(where: { $0.value.page == page }),
              let index = model.tabs.firstIndex(where: { $0.id == tabID }) else {
            adw_tab_view_close_page_finish(tabView, page, 1)
            return true
        }
        pages[tabID] = nil
        adw_tab_view_close_page_finish(tabView, page, 1)
        setModel(model.closingTab(at: index))
        return true
    }

    private func selectedPageChanged() {
        guard !syncing, let model, let page = adw_tab_view_get_selected_page(tabView),
              let (tabID, _) = pages.first(where: { $0.value.page == page }),
              let index = model.tabs.firstIndex(where: { $0.id == tabID }), index != model.selectedIndex else { return }
        var next = model
        while next.selectedIndex != index { next = next.selectingNextTab() }
        setModel(next)
    }

    // MARK: Vault banner

    func updateBanner() {
        switch app.vaultState {
        case .opened:
            adw_banner_set_revealed(cast(banner), 0)
        case .locked, .loading:
            adw_banner_set_title(cast(banner), app.vaultState == .loading ? "Opening the vault…" : "The vault is locked: ssh has no vault keys.")
            adw_banner_set_button_label(cast(banner), app.vaultState == .loading ? nil : "Unlock")
            adw_banner_set_revealed(cast(banner), 1)
        case .none:
            adw_banner_set_title(cast(banner), "No vault on this device yet.")
            adw_banner_set_button_label(cast(banner), "Set Up")
            adw_banner_set_revealed(cast(banner), 1)
        }
    }

    /// Re-applies font, scrollback and colours to every terminal.
    func applySettings() {
        for pane in panes.values { pane.apply(app.settings, dark: app.isDark) }
    }

    /// Every pane on screen whose stripes show has them filling exactly its own allocation, at its own place in
    /// the window (the smoke test).
    var hatchesFit: Bool {
        guard let model else { return true }
        return model.selectedTab.visibleFrames.keys.allSatisfy { id in
            guard let g = panes[id]?.hatchGeometry, g.visible else { return true }
            return g.width == g.paneWidth && g.height == g.paneHeight
        }
    }

    /// What the smoke test reads: tabs, panes per tab, the focused pane's text.
    func snapshot() -> [String: Any] {
        guard let model else { return ["tabs": 0] }
        return [
            "tabs": model.tabs.count,
            "selected": model.selectedIndex,
            "sidebarVisible": sidebar.map { gtk_widget_get_visible($0.widget) != 0 } ?? false,
            "panes": model.tabs.map(\.panes.count),
            "broadcast": "\(app.broadcast.mode)",
            "receiving": model.tabs.flatMap(\.paneIDs).filter { app.isReceiving($0, focused: model.selectedTab.focused) }.count,
            "everyPaneStriped": model.tabs.flatMap(\.paneIDs).allSatisfy { app.isReceiving($0, focused: model.selectedTab.focused) },
            "hatchesFit": hatchesFit,
            "focusedTitle": focusedPane?.title ?? "",
            "tabTitles": tabLabels.map(\.title),
            "tabSubtitles": tabLabels.map(\.subtitle),
            "windowTitle": string(gtk_window_get_title(cast(window))),
            "screens": screens.values.map(\.state),
            "focusedText": focusedPane?.text() ?? "",
            "loginBars": loginBars,
            "texts": model.selectedTab.paneIDs.map { panes[$0]?.text() ?? "" },
        ]
    }
}
