// The application: windows, settings, the built-in agent, the vault (unlock, ssh_config, Include offer), Google
// Drive sign-in and updates. Everything runs on the GTK main thread; slow work goes through `background`.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

enum VaultState: Equatable { case loading, none, locked, opened }

@MainActor
final class AppController {
    let gtkApp: OpaquePointer
    let environment: [String: String]
    let home: String
    /// The home OpenSSH uses for ~/.ssh/config: the passwd entry's, which can differ from $HOME.
    let sshHome: String
    private(set) var windows: [MainWindow] = []
    var settings: AppSettings
    let settingsURL: URL
    var keybindings = Keybindings.defaults(for: .linux)

    private(set) var vaultState = VaultState.loading
    /// Something asked for the vault (Servers, a server, host search, a restored server pane): only then does the
    /// master password dialog come up by itself. A plain launch opens a local shell and never asks.
    private var vaultWanted = false
    private var started = false
    /// What to do once the vault opens (the request that needed it).
    private var afterVaultOpens: [() -> Void] = []
    /// The servers sidebar: hidden at launch (a terminal first), F9 or Servers… shows it.
    var sidebarShown = false
    /// The command line of the first launch (-e, --working-directory, ssh://), applied to the first window.
    var launchArguments = TerminalArguments()
    var vault: Vault?
    private var session: VaultSession?
    private var needsMasterPassword = false
    private var secrets: (any SecretStore)?
    private var tokens: GoogleTokenManager?
    let googleConfig: GoogleOAuthConfig?

    private var agent: DesktopAgent?
    private(set) var agentSocket: String?
    let sshWriter: SSHConfigWriter
    private let lastCheck: LastCheck
    private var updates: UpdateService?
    private(set) lazy var menuModel: OpaquePointer = makeMenu()
    let testStateFile: String?

    init(gtkApp: OpaquePointer, environment: [String: String]) {
        self.gtkApp = gtkApp
        self.environment = environment
        home = environment["HOME"] ?? NSHomeDirectory()
        sshHome = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? home
        settingsURL = AppSettings.defaultURL(environment: environment, home: home)
        settings = AppSettings.load(from: settingsURL)
        sshWriter = SSHConfigWriter(directory: SSHConfigWriter.defaultDirectory(environment: environment, home: home))
        googleConfig = try? GoogleOAuthConfig.fromEnvironment(environment)
        lastCheck = LastCheck(settings.lastUpdateCheck)
        testStateFile = environment["RSSHTERM_TEST_STATE"]
    }

    // MARK: Lifecycle

    func activate() {
        guard !started else {
            // Started already (the servers or files window kept the app alive): bring a terminal up.
            if windows.isEmpty { openFromArguments() } else { windows.last?.present() }
            return
        }
        started = true
        MainActorPump.install()
        addActions()
        gtk_window_set_default_icon_name("dev.rsshterm.RSSHTerm")
        installConnectIcons()
        installCSS()
        applyColorScheme()
        onNotify(adw_style_manager_get_default(), "dark") { [unowned self] in
            windows.forEach { $0.applySettings() }
        }
        startAgent()
        restoreOrOpen()
        startVault()
        startTitlePolling()
        every(seconds: 5) { [unowned self] in
            saveSession()
            return true
        }
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            let cb: @convention(c) (gpointer?) -> gboolean = { _ in
                controller?.quit()
                return 0
            }
            g_unix_signal_add(signal, cb, nil)
        }
        if environment["RSSHTERM_NO_UPDATE_CHECK"] == nil {
            every(seconds: 10) { [unowned self] in
                checkForUpdates(.launch)
                every(seconds: 3600) { [unowned self] in
                    checkForUpdates(.periodic)
                    return true
                }
                return false
            }
        }
        if testStateFile != nil {
            every(milliseconds: 300) { [unowned self] in
                writeTestState()
                return true
            }
        }
    }

    func openWindow(restoring: Window? = nil, first: PaneContent? = nil, title: String? = nil) {
        let w = MainWindow(app: self, gtkApp: gtkApp,
                           restoring: restoring ?? first.map { Window(tabs: [Tab(title: title, pane: Pane(content: $0))]) })
        windows.append(w)
        w.present()
        if let warning = secretsWarningShown { w.toast(warning) }
    }

    /// `emptied`: its last tab closed (the session then forgets it); otherwise the window was closed or the app quits,
    /// and the last saved session keeps it for the next launch.
    func windowClosed(_ w: MainWindow, emptied: Bool) {
        guard windows.contains(where: { $0 === w }) else { return }
        if emptied {
            windows.removeAll { $0 === w }
            saveSession(force: true)
        } else {
            if windows.count > 1 { windows.removeAll { $0 === w }; saveSession() } else { windows.removeAll { $0 === w } }
        }
    }

    // MARK: Broadcast input

    private(set) var broadcast = BroadcastState()

    var focusedPaneID: PaneID? { activeWindow?.model?.selectedTab.focused }
    private var allModels: [Window] { windows.compactMap(\.model) }
    private var visiblePanes: Set<PaneID> { windows.reduce(into: []) { $0.formUnion($1.visiblePanes) } }

    func pane(_ id: PaneID) -> TerminalPane? { windows.lazy.compactMap { $0.pane(id) }.first }

    /// `source` first, then every other pane that gets what is typed there.
    func broadcastTargets(from source: PaneID) -> [PaneID] {
        let t = broadcast.targets(for: source, windows: allModels, visible: visiblePanes)
        return t.isEmpty ? [source] : t
    }

    func isReceiving(_ id: PaneID, focused: PaneID?) -> Bool {
        broadcast.isReceiving(id, windows: allModels, visible: visiblePanes, focused: focused)
    }

    func applyBroadcast(_ action: DesktopAction, focused: PaneID) {
        setBroadcast(broadcast.applying(action, focused: focused))
    }

    func setBroadcast(_ state: BroadcastState) {
        broadcast = state
        layoutChanged()
        let text: String = switch state.mode {
        case .currentOnly: "Broadcast off: input goes to the current pane only."
        case .allTabs: "Broadcasting to every pane in this window's tabs."
        case .currentTab: "Broadcasting to every pane in this tab."
        case .visible: "Broadcasting to every visible pane."
        case .manual: "Broadcasting to \(state.manual.count) chosen pane(s)."
        }
        activeWindow?.toast(text)
    }

    /// The badge of `id` was clicked: the pane typed in stops the broadcast, another pane leaves it.
    func stopBroadcast(to id: PaneID) {
        let reached = focusedPaneID.map { broadcastTargets(from: $0) } ?? []
        setBroadcast(broadcast.removing(id, reached: reached, source: focusedPaneID))
    }

    /// Panes closed or moved: drop gone panes from the hand-picked set, redraw the indicators.
    func layoutChanged() {
        broadcast = broadcast.pruned(existing: Set(allModels.flatMap { $0.tabs.flatMap(\.paneIDs) }))
        windows.forEach { $0.updateBroadcastIndicators() }
        stateChanged()
    }

    func showBroadcastPicker(over window: MainWindow) {
        guard let focused = window.model?.selectedTab.focused else { return }
        var hosts: [PaneID: String] = [:]
        var groups: [PaneID: UUID] = [:]
        for model in allModels {
            for p in model.tabs.flatMap(\.panes) {
                guard case .ssh(let serverID) = p.content, let server = vault?.servers.first(where: { $0.id == serverID }) else { continue }
                hosts[p.id] = server.host
                if let g = server.groupID { groups[p.id] = g }
            }
        }
        let presets = BroadcastPresets.presets(for: focused, windows: allModels, visible: visiblePanes, hosts: hosts, groups: groups)
        var states: [PaneID: PaneTitleState] = [:]
        for id in allModels.flatMap({ $0.tabs.flatMap(\.paneIDs) }) { states[id] = pane(id)?.titleState }
        let rows = titleContext.describePanes(windows: allModels, states: states, current: focused)
        let current: Set<PaneID> = broadcast.mode == .currentOnly ? [] : Set(broadcastTargets(from: focused))
        BroadcastPicker(presets: presets, panes: rows, checked: current, parent: window.window) { [unowned self] chosen in
            setBroadcast(broadcast.broadcasting(to: chosen))
        }.present()
    }

    func readClipboard(from widget: Widget, _ done: @escaping (String?) -> Void) {
        let clipboard = gtk_widget_get_clipboard(widget)
        let box = Unmanaged.passRetained(ClipboardRequest(done)).toOpaque()
        gdk_clipboard_read_text_async(clipboard, nil, { source, result, data in
            let request = Unmanaged<ClipboardRequest>.fromOpaque(data!).takeRetainedValue()
            var error: UnsafeMutablePointer<GError>?
            let text = gdk_clipboard_read_text_finish(OpaquePointer(source), result, &error)
            if let error { g_error_free(error) }
            request.done(text.map { String(cString: $0) })
            g_free(text)
        }, box)
    }

    /// The "How to connect" glyphs (SSH, RDP, VNC, Screen Sharing) as symbolic icons GTK finds by name.
    func installConnectIcons() {
        do {
            let root = try ConnectIcons.install(into: ConnectIcons.defaultRoot())
            gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(gdk_display_get_default()), root.path)
        } catch {
            FileHandle.standardError.write(Data("rsshterm: connect icons not written: \(error)\n".utf8))
        }
    }

    func installCSS() {
        let provider = gtk_css_provider_new()
        gtk_css_provider_load_from_string(provider, """
            .broadcast-badge { color: #ff6b6b; min-width: 0; min-height: 0; padding: 3px 6px; border-radius: 7px; }
            .tab-strip .tab-item { padding: 2px 8px; border-radius: 8px; }
            .tab-strip .tab-item.selected-tab { background-color: alpha(currentColor, 0.12); }
            .file-pane { border: 2px solid transparent; border-radius: 6px; }
            .file-pane.active-pane { border-color: alpha(@accent_bg_color, 0.6); }
            .file-list row.marked { background-color: alpha(@warning_bg_color, 0.35); }
            .file-list row.marked label { font-weight: bold; }
            """)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), cast(provider), 600)
    }

    // MARK: Tab titles

    private var cachedTitleContext: TabTitleContext?

    /// The vault's servers and screens, ~/.ssh/config (and the generated one) and Settings › Tab Titles.
    var titleContext: TabTitleContext {
        if let cachedTitleContext { return cachedTitleContext }
        let configs = ["\(sshHome)/.ssh/config", sshWriter.configPath].compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let context = TabTitleContext(servers: vault?.servers ?? [], remoteDesktops: vault?.remoteDesktops ?? [],
                                      sshConfigText: configs.joined(separator: "\n"), settings: settings.tabTitles)
        cachedTitleContext = context
        return context
    }

    /// The vault, ssh_config or the templates changed: relabel every tab.
    func titlesChanged() {
        cachedTitleContext = nil
        windows.forEach { $0.updateTitles() }
    }

    private func startTitlePolling() {
        let user = environment["USER"] ?? NSUserName()
        let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init)
        let homeDir = home
        every(seconds: 1) { [unowned self] in
            windows.forEach { $0.pollTitles(user: user, host: host, home: homeDir) }
            return true
        }
    }

    // MARK: Session restore

    private var lastSavedSession: Data?
    private var savePending = false
    lazy var sessionURL = SessionStore.defaultURL(environment: environment, home: home)

    /// Writes the windows (and the shells' directories) when they changed. With no window left it writes only when
    /// `force` (the last tab was closed on purpose).
    func saveSession(force: Bool = false) {
        guard !windows.isEmpty || force else { return }
        var dirs: [PaneID: String] = [:]
        for w in windows { dirs.merge(w.directories) { a, _ in a } }
        let session = SessionSnapshot.capture(windows: windows.compactMap(\.model), directories: dirs)
        guard let data = try? JSONEncoder().encode(session), data != lastSavedSession else { return }
        do {
            try SessionStore.save(session, to: sessionURL)
            lastSavedSession = data
        } catch {
            fputs("rsshterm: session not saved: \(error)\n", stderr)
        }
    }

    /// A terminal first (docs/desktop/terminal-first.md): the restored windows or one local shell; a command line
    /// (-e, --working-directory) opens just that.
    private func restoreOrOpen() {
        if launchArguments.localContent != nil {
            openFromArguments()
        } else {
            let plan = LaunchPlan.make(restoreSession: settings.restoreSession,
                                       saved: settings.restoreSession ? SessionStore.load(from: sessionURL) : nil)
            for window in plan.windows { openWindow(restoring: window) }
            vaultWanted = plan.needsVault
        }
        if let url = launchArguments.url { openSSHURL(url) }
        launchArguments = TerminalArguments()
    }

    /// A window for the command line's tab (-e, --working-directory, -T), else a local shell.
    private func openFromArguments() {
        openWindow(first: launchArguments.localContent ?? .localShell(), title: launchArguments.title)
        if let url = launchArguments.url { openSSHURL(url) }
        launchArguments = TerminalArguments()
    }

    /// Ctrl+Shift+T / Ctrl+Shift+N / a server, from anywhere (the menu, D-Bus, another instance): the active window
    /// as a tab, or a new window when there is none.
    func route(_ request: TerminalRequest, title: String? = nil) {
        let front = activeWindow.map { [ObjectIdentifier($0)] } ?? []
        switch TerminalRouting.target(for: request, frontToBack: front) {
        case .tab:
            guard let w = activeWindow else { return }
            if request == .newLocalTab { w.perform(.newTab) } else { w.openTab(TerminalRouting.content(of: request), title: title) }
            w.present()
        case .newWindow:
            openWindow(first: TerminalRouting.content(of: request), title: title)
        }
    }

    /// Another `rsshterm …` while this one runs (GApplication forwards its command line here): -e and
    /// --working-directory open a tab, ssh:// opens that server, no arguments brings a window up (a new one if none).
    func commandLine(_ arguments: [String], directory: String?) -> Int32 {
        var parsed: TerminalArguments
        do { parsed = try TerminalArguments.parse(arguments) } catch {
            fputs("rsshterm: \(error.localizedDescription)\nusage: rsshterm [-e command [args…]] [--working-directory DIR] [-T title] [ssh://user@host:port]\n", stderr)
            return 2
        }
        // `-e cmd` runs where the caller is, as GNOME Terminal and xterm do.
        if parsed.command != nil, parsed.directory == nil { parsed.directory = directory }
        guard !windows.isEmpty else {
            launchArguments = parsed
            activate()
            return 0
        }
        if let content = parsed.localContent {
            route(.open(content), title: parsed.title)
        } else if let url = parsed.url {
            openSSHURL(url)
        } else {
            windows.last?.present()
        }
        return 0
    }

    /// ssh://: a saved server, Quick Connect, or ssh in a local tab (no user and no matching server).
    func openSSHURL(_ url: SSHURL) {
        if url.username == nil, vault == nil, case .command(let argv) = url.opening(in: []) {
            return route(.open(.localShell(command: argv)))
        }
        whenVaultOpens { [unowned self] in
            switch url.opening(in: vault?.servers ?? []) {
            case .server(let id): route(.open(.ssh(serverID: id)))
            case .quickConnect(let address): if let w = activeWindow { showQuickConnect(over: w, address: address) }
            case .command(let argv): route(.open(.localShell(command: argv)))
            }
        }
    }

    /// Runs `action` with the vault open: now, or after the unlock this starts (master password, set up, keyring).
    func whenVaultOpens(_ action: @escaping () -> Void) {
        guard vaultState != .opened else { return action() }
        afterVaultOpens.append(action)
        vaultWanted = true
        switch vaultState {
        case .none: setUpVault()
        case .locked: needsMasterPassword ? askMasterPassword() : reunlock()
        case .loading, .opened: break
        }
    }

    func quit() {
        saveSession()
        g_application_quit(cast(gtkApp))
    }

    var activeWindow: MainWindow? {
        let active = gtk_application_get_active_window(cast(gtkApp))
        return windows.first { UnsafeMutableRawPointer($0.window) == active.gptr } ?? windows.last
    }

    var isDark: Bool { adw_style_manager_get_dark(adw_style_manager_get_default()) != 0 }

    /// A layout change: saved a second later (several changes in a row are written once).
    func stateChanged() {
        guard !savePending else { return }
        savePending = true
        every(seconds: 1) { [unowned self] in
            savePending = false
            saveSession()
            return false
        }
    }

    // MARK: Terminals

    func spawnPlan(for content: PaneContent, override: SSHLoginOverride? = nil) -> Result<SpawnPlan, SpawnError> {
        let userConfig = (try? String(contentsOfFile: "\(sshHome)/.ssh/config", encoding: .utf8)) ?? ""
        let planner = SpawnPlanner(environment: environment, agentSocket: agentSocket, appVersion: RSSHTermVersion.current,
                                   sshConfigPath: sshWriter.configPath,
                                   includeInstalled: SSHInclude.isInstalled(in: userConfig, configPath: sshWriter.configPath,
                                                                            home: sshHome))
        return planner.plan(content, servers: vault?.servers ?? [], override: override)
    }

    private func startAgent() {
        let path = AgentSocketPath.default(environment: environment, home: home)
        let a = DesktopAgent(socketPath: path)
        do {
            try a.start()
            agent = a
            agentSocket = path
        } catch {
            agentSocket = nil
            secretsWarningShown = "The built-in ssh-agent could not start (\(error)); tabs keep your own agent."
        }
    }

    func saveSettings() {
        do { try settings.save(to: settingsURL) } catch { activeWindow?.toast("Settings not saved: \(error.localizedDescription)") }
    }

    // MARK: Vault

    private var secretsWarningShown: String?

    private func startVault() {
        setVaultState(.loading)
        let env = environment
        background({ await DesktopSecretStore.select(runner: ProcessCommandRunner(), environment: env) }) { [unowned self] choice in
            secrets = choice.store
            if let warning = choice.warning {
                secretsWarningShown = "No keyring: this device's key is kept in a file only you can read."
                activeWindow?.toast(secretsWarningShown!)
                fputs("rsshterm: \(warning)\n", stderr)
            }
            if let googleConfig { tokens = GoogleTokenManager(oauth: GoogleDesktopOAuth(config: googleConfig), secrets: choice.store) }
            makeSession { [unowned self] in loadVault() }
        }
    }

    /// The vault file in $XDG_DATA_HOME/rssh, mirrored with Google Drive once signed in.
    nonisolated static func localStore(environment: [String: String], home: String) -> LocalFileVaultStore {
        let base = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "\(home)/.local/share"
        return LocalFileVaultStore(fileURL: URL(fileURLWithPath: "\(base)/rssh/vault.json"))
    }

    private func makeSession(_ done: @escaping () -> Void) {
        guard let secrets else { return }
        let tokens = self.tokens
        let local = Self.localStore(environment: environment, home: home)
        background({ await tokens?.isSignedIn() ?? false }) { [unowned self] signedIn in
            let store: any VaultStore
            if signedIn, let tokens {
                store = MirroredVaultStore(primary: GoogleDriveVaultStore { try await tokens.accessToken() }, mirror: local)
            } else {
                store = local
            }
            session = VaultSession(store: store, deviceKeys: SecretStoreDeviceKeyStore(secrets: secrets),
                                   deviceName: ProcessInfo.processInfo.hostName)
            done()
        }
    }

    func loadVault() {
        guard let session else { return }
        setVaultState(.loading)
        background({ await Result.of { try await session.load() } }) { [unowned self] result in
            switch result {
            case .success(.noVault):
                setVaultState(.none)
            case .success(.needsMasterPassword):
                needsMasterPassword = true
                setVaultState(.locked)
                if vaultWanted { askMasterPassword() }
            case .success(.opened(let v)):
                activateVault(v)
            case .failure(let error):
                setVaultState(.locked)
                activeWindow?.toast("The vault could not be opened: \(error.localizedDescription)")
            }
        }
    }

    private func setVaultState(_ state: VaultState) {
        vaultState = state
        windows.forEach { $0.updateBanner() }
    }

    func bannerAction(from window: MainWindow) {
        vaultWanted = true
        switch vaultState {
        case .none: setUpVault()
        case .locked: needsMasterPassword ? askMasterPassword() : reunlock()
        case .loading, .opened: break
        }
    }

    /// A new device: the master password opens the vault, and the vault is saved with this device's key.
    func askMasterPassword(retry: Bool = false) {
        guard let parent = activeWindow?.window, let session else { return }
        let body = retry ? "That password does not open the vault. Try again."
            : "This device has not opened the vault before. Enter the master password; next time it opens without it."
        askPassword("Unlock Vault", body, action: "Unlock", parent: parent) { [unowned self] password in
            setVaultState(.loading)
            background({ await Result.of { try await session.unlock(masterPassword: password) } }) { [unowned self] result in
                switch result {
                case .success(let v):
                    needsMasterPassword = false
                    activateVault(v)
                case .failure(VaultSessionError.wrongPassword):
                    setVaultState(.locked)
                    askMasterPassword(retry: true)
                case .failure(let error):
                    setVaultState(.locked)
                    activeWindow?.toast(error.localizedDescription)
                }
            }
        }
    }

    /// After Lock: the master password when the vault has one, else the device key alone.
    private func reunlock() {
        guard let session, let parent = activeWindow?.window else { return }
        background({ await session.hasMasterPassword }) { [unowned self] hasPassword in
            guard hasPassword else { return loadVault() }
            askPassword("Unlock Vault", "Enter the master password.", action: "Unlock", parent: parent) { [unowned self] password in
                background({ await (try? session.verify(masterPassword: password)) ?? false }) { [unowned self] ok in
                    ok ? loadVault() : activeWindow?.toast("Wrong master password.")
                }
            }
        }
    }

    func lockVault() {
        guard vaultState == .opened else { return }
        agent?.setKeys([])
        vault = nil
        windows.forEach { $0.detachServerList() }
        if let places { Task { @MainActor in await places.closeAll() } }
        if let w = commanderWindow?.windowWidget { gtk_window_destroy(cast(w)) }
        commanderWindow = nil
        document = nil
        places = nil
        serverList = nil
        if let session { Task { await session.lock() } }
        setVaultState(.locked)
        activeWindow?.toast("Vault locked: ssh no longer sees the vault keys.")
    }

    /// No vault yet: create one with a master password (or sign in to Google Drive to find the one other devices use).
    func setUpVault() {
        guard let parent = activeWindow?.window, let session else { return }
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        let first = passwordEntry(placeholder: "Master password")
        let second = passwordEntry(placeholder: "Repeat it")
        gtk_box_append(cast(box), label("Master password", css: ["caption-heading"]))
        gtk_box_append(cast(box), first)
        gtk_box_append(cast(box), label("Repeat", css: ["caption-heading"]))
        gtk_box_append(cast(box), second)
        var responses = [Response(id: "cancel", label: "Cancel")]
        if googleConfig != nil { responses.append(Response(id: "google", label: "Use Google Drive")) }
        responses.append(Response(id: "create", label: "Create Vault", look: .suggested))
        alert("Set Up the Vault",
              "Servers and keys are kept encrypted on this device. The master password opens the vault on a new device.",
              responses: responses, defaultID: "create", extra: box, parent: parent) { [unowned self] id in
            switch id {
            case "google": signInToGoogle()
            case "create":
                let password = entryText(first)
                guard password == entryText(second) else { return activeWindow?.toast("The passwords differ.") ?? () }
                background({ await Result.of { try await session.create(masterPassword: password) } }) { [unowned self] result in
                    switch result {
                    case .success(let v): activateVault(v)
                    case .failure(let e): activeWindow?.toast(e.localizedDescription)
                    }
                }
            default: break
            }
        }
    }

    /// Keys to the agent, ssh_config written, the Include offered once.
    private func activateVault(_ v: Vault) {
        vault = v
        let (keys, skipped) = DesktopAgentKeys.load(v.credentials)
        agent?.setKeys(keys)
        let socket = agentSocket ?? AgentSocketPath.default(environment: environment, home: home)
        let files = SSHConfigGenerator.generate(servers: v.servers, keys: keys.map(SSHConfigKey.init),
                                                agentSocket: socket, keyDirectory: sshWriter.keyDirectory)
        do { try sshWriter.write(files) } catch { activeWindow?.toast("ssh_config not written: \(error.localizedDescription)") }
        makeDocument(v, agentSocket: socket)
        setVaultState(.opened)
        titlesChanged()
        windows.forEach { $0.spawnPending() }
        if !skipped.isEmpty {
            activeWindow?.toast("\(skipped.count) key(s) not offered to ssh: see Keys.")
        }
        offerInclude()
        let pending = afterVaultOpens
        afterVaultOpens = []
        pending.forEach { $0() }
    }

    // MARK: Servers and files (RSSHDesktopCore models)

    /// The unlocked vault as the server/file models edit it: saves through the session, then regenerates
    /// ssh_config and the agent's keys.
    private(set) var document: SavingVaultDocument?
    private(set) var places: FilePlaces?
    private(set) var serverList: ServerListModel?
    var commanderWindow: CommanderWindow?

    private func makeDocument(_ v: Vault, agentSocket socket: String) {
        if let document {
            document.replace(with: v)
            return
        }
        guard let session else { return }
        let doc = SavingVaultDocument(
            vault: v, save: { vault in try await session.save(vault) },
            afterSave: [SSHConfigRefresh.hook(agentSocket: socket, writer: sshWriter) { [weak self] error in
                self?.activeWindow?.toast("ssh_config not written: \(error.localizedDescription)")
            }])
        doc.addAfterSave { [weak self] vault in
            guard let self else { return }
            self.vault = vault
            self.agent?.setKeys(DesktopAgentKeys.load(vault.credentials).keys)
            self.titlesChanged()
        }
        document = doc
        places = FilePlaces(document: doc)
        serverList = ServerListModel(document: doc)
        windows.forEach { $0.attachServerList() }
    }

    func showCommander(at target: OpenHere.Target? = nil) {
        guard let places else { return whenVaultOpens { [unowned self] in showCommander(at: target) } }
        let window = commanderWindow ?? CommanderWindow(app: self, places: places)
        commanderWindow = window
        window.present()
        guard let target else { return }
        run {
            if let path = target.path {
                await window.commander.show(target.place, at: path)
            } else {
                window.commander.activeSide = .left // as show(_:at:) does
                await window.commander.left.switchTo(target.place) // the place's own start folder
            }
        }
    }

    func showNetworkScan() {
        guard let document, let parent = activeWindow?.window else { return activeWindow?.toast("Unlock the vault first.") ?? () }
        NetworkScanDialog(model: NetworkScanModel(document: document), parent: parent).present()
    }

    func showSSHConfigImport() {
        guard let document, let list = serverList, let parent = activeWindow?.window else {
            return activeWindow?.toast("Unlock the vault first.") ?? ()
        }
        let path = "\(sshHome)/.ssh/config"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return message("No ~/.ssh/config", "\(path) could not be read.", parent: parent)
        }
        ImportSSHConfigDialog(list: list, credentials: CredentialsModel(document: document), sshConfigText: text, home: sshHome,
                              user: environment["USER"] ?? NSUserName(), parent: parent).present()
    }

    func showQuickConnect(over window: MainWindow, address: QuickAddress? = nil) {
        guard let document else {
            return whenVaultOpens { [unowned self, weak window] in
                if let window { showQuickConnect(over: window, address: address) }
            }
        }
        QuickConnectDialog(model: QuickConnectModel(document: document, address: address), window: window).present()
    }

    /// "Open File Manager Here" for the focused pane.
    func openFileManagerHere(from window: MainWindow) {
        guard let pane = window.focusedPane, let content = window.focusedContent else { return }
        let target = OpenHere.target(content: content, directory: pane.shellDirectory, home: home,
                                     localHostName: ProcessInfo.processInfo.hostName)
        showCommander(at: target)
    }

    private func offerInclude() {
        let userConfig = (try? String(contentsOfFile: "\(sshHome)/.ssh/config", encoding: .utf8)) ?? ""
        guard !settings.includeOffered,
              !SSHInclude.isInstalled(in: userConfig, configPath: sshWriter.configPath, home: sshHome),
              let parent = activeWindow?.window else { return }
        let line = "Include \(SSHInclude.spelling(of: sshWriter.configPath, home: sshHome))"
        alert("Use vault servers everywhere?",
              "Add “\(line)” to the top of ~/.ssh/config so ssh, scp, rsync and git know the vault's servers by name, in any terminal. rSshTerm's own tabs work either way.",
              responses: [Response(id: "no", label: "Not Now"), Response(id: "add", label: "Add Include", look: .suggested)],
              defaultID: "add", parent: parent) { [unowned self] id in
            settings.includeOffered = true
            saveSettings()
            guard id == "add" else { return }
            do {
                try SSHInclude.install(home: sshHome, configPath: sshWriter.configPath)
                activeWindow?.toast("Added to ~/.ssh/config.")
            } catch {
                activeWindow?.toast("~/.ssh/config not changed: \(error.localizedDescription)")
            }
        }
    }

    /// Verifies the master password before private key material is shown.
    func reauthenticate(parent: Widget, reason: String, then: @escaping () -> Void) {
        guard let session else { return }
        background({ await session.hasMasterPassword }) { hasPassword in
            guard hasPassword else {
                return message("Master password needed", "Set a master password on the vault to view private keys.", parent: parent)
            }
            askPassword("Confirm It's You", reason, action: "Show", parent: parent) { password in
                background({ await (try? session.verify(masterPassword: password)) ?? false }) { ok in
                    ok ? then() : message("Wrong password", "The private key stays hidden.", parent: parent)
                }
            }
        }
    }

    // MARK: Google Drive

    func signInToGoogle() {
        guard let tokens, let runner = Optional(ProcessCommandRunner()) else {
            activeWindow?.toast("Google sign-in is not configured (RSSH_GOOGLE_CLIENT_ID).")
            return
        }
        activeWindow?.toast("Continue in your browser…")
        background({ await Result.of { try await tokens.signIn(browser: SystemBrowserOpener(runner: runner),
                                                            receiver: try LoopbackRedirectReceiver()) } }) { [unowned self] result in
            switch result {
            case .success:
                activeWindow?.toast("Signed in to Google Drive.")
                makeSession { [unowned self] in loadVault() }
            case .failure(let error):
                activeWindow?.toast("Google sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Updates

    private func updateService() -> UpdateService {
        if let updates { return updates }
        let exePath = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
        let exe = URL(fileURLWithPath: exePath)
        let kind = InstallKind.detect(executable: exe, environment: environment)
        let plan = UpdatePlanner.plan(for: kind, pkexecPath: UpdatePlanner.findPkexec())
        let base = environment["RSSHTERM_UPDATE_BASE_URL"].flatMap(URL.init(string:)) ?? UpdateChecker.defaultBaseURL
        // An AppImage relaunches itself (the file), not the binary inside its mount.
        let relaunch = if case .appImage(let file) = kind { file.path } else { exePath }
        let installer = UpdateInstaller(checker: UpdateChecker(baseURL: base), relaunchExecutable: relaunch)
        let last = lastCheck
        let service = UpdateService(current: SemanticVersion(RSSHTermVersion.current)!,
                                    assetKey: UpdatePlatformKey.key(for: kind, architecture: UpdatePlatformKey.currentArchitecture),
                                    plan: plan, installer: installer, autoInstall: settings.autoInstallUpdates,
                                    loadLastCheck: { last.value }, saveLastCheck: { last.value = $0 })
        updates = service
        return service
    }

    func resetUpdateService() { updates = nil }

    func checkForUpdates(_ trigger: UpdateService.Trigger) {
        let service = updateService()
        let manual = trigger == .manual
        background({ () -> Result<UpdateService.Outcome, UpdateError> in
            do { return .success(try await service.run(trigger)) } catch let error as UpdateError {
                return .failure(error)
            } catch {
                return .failure(.transport("\(error)"))
            }
        }) { [unowned self] result in
            if let date = lastCheck.value, date != settings.lastUpdateCheck {
                settings.lastUpdateCheck = date
                saveSettings()
            }
            let msg: UpdatePresenter.Message?
            switch result {
            case .success(let outcome): msg = UpdatePresenter.message(for: outcome, manual: manual)
            case .failure(let error): msg = UpdatePresenter.message(for: error, manual: manual)
            }
            if let msg { presentUpdate(msg) }
        }
    }

    private func presentUpdate(_ msg: UpdatePresenter.Message) {
        guard let parent = activeWindow?.window else { return }
        var responses = [Response(id: "close", label: "Close")]
        switch msg.action {
        case .install?: responses.append(Response(id: "install", label: "Install", look: .suggested))
        case .quit?: responses = [Response(id: "quit", label: "Restart", look: .suggested)]
        case .copy?: responses.append(Response(id: "copy", label: "Copy Command", look: .suggested))
        case .openDownloads?: responses.append(Response(id: "open", label: "Open Download Page", look: .suggested))
        case nil: break
        }
        alert(msg.title, msg.body, responses: responses, defaultID: responses.last?.id, parent: parent) { [unowned self] id in
            switch (id, msg.action) {
            case ("install", _): checkForUpdates(.manual)
            case ("quit", _): quit()
            case ("copy", .copy(let command)?): copyToClipboard(command, from: parent)
            case ("open", _): gtk_uri_launcher_launch(gtk_uri_launcher_new(UpdatePresenter.downloadsURL), cast(parent), nil, nil, nil)
            default: break
            }
        }
    }

    // MARK: Look

    func applyColorScheme() {
        let scheme: AdwColorScheme = switch settings.colorScheme {
        case .system: ADW_COLOR_SCHEME_DEFAULT
        case .light: ADW_COLOR_SCHEME_FORCE_LIGHT
        case .dark: ADW_COLOR_SCHEME_FORCE_DARK
        }
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), scheme)
    }

    func settingsChanged() {
        saveSettings()
        applyColorScheme()
        windows.forEach { $0.applySettings() }
        titlesChanged()
        layoutChanged()
        resetUpdateService()
    }

    // MARK: Dialogs

    func showHostSearch(over window: MainWindow) {
        guard let vault else {
            if vaultState == .loading { window.toast("Opening the vault…") }
            return whenVaultOpens { [unowned self, weak window] in if let window { showHostSearch(over: window) } }
        }
        HostSearchDialog.present(servers: vault.servers, groups: vault.groups, desktops: vault.remoteDesktops, over: window)
    }

    func showJumpSwitcher(over window: MainWindow) { JumpSwitcherDialog.present(app: self, over: window) }

    func showKeys() {
        guard let window = activeWindow else { return }
        guard let vault else { return whenVaultOpens { [unowned self] in showKeys() } }
        guard let document else { return }
        KeysDialog(app: self, model: CredentialsModel(document: document), parent: window.window).present()
    }

    func showPreferences(tabTitles: Bool = false) {
        guard let window = activeWindow else { return }
        let dialog = PreferencesDialog(app: self, parent: window.window)
        dialog.present()
        if tabTitles { dialog.showTabTitles() }
    }

    // MARK: Test hook

    /// RSSHTERM_TEST_STATE: the smoke test reads tabs, panes and terminal text from this JSON file.
    private func writeTestState() {
        guard let testStateFile else { return }
        let state: [String: Any] = [
            "vault": "\(vaultState)",
            "servers": vault?.servers.count ?? 0,
            "serverUsers": vault?.servers.map(\.username) ?? [],
            "windows": windows.map { $0.snapshot() },
            "files": commanderWindow?.snapshot() ?? [:],
            "sidebarServers": serverList?.visibleServers.count ?? 0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: testStateFile), options: .atomic)
    }
}

final class ClipboardRequest {
    let done: (String?) -> Void
    init(_ done: @escaping (String?) -> Void) { self.done = done }
}

/// The last update check, shared with the update actor's closures.
final class LastCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?
    init(_ date: Date?) { self.date = date }
    var value: Date? {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}

extension Result where Failure == any Error {
    /// `await Result.of { try await … }`
    static func of(_ body: () async throws -> Success) async -> Result {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
