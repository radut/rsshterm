// "The server refused the login" on an ssh pane: a bar with Try Another Login… and Retry, the picker (user + key or
// a password ssh asks for), the same pane started again with that login, and once it logs in "Save … for <server>?".
// Never retried on its own. Driven by PaneLoginRetry (RSSHDesktopCore).
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

extension MainWindow {
    static let refusedMessage = SSHFailure.authenticationFailed.message

    func loginRefused(_ id: PaneID) {
        guard let pane = pane(id), let server = pane.server.flatMap({ s in app.vault?.servers.first { $0.id == s.id } })
        else { return }
        var retry = loginRetries[id] ?? PaneLoginRetry(server: server)
        retry.refused()
        loginRetries[id] = retry
        pane.showBar(Self.refusedMessage, buttons: [
            ("Try Another Login…", false, { [weak self] in self?.pickLogin(id) }),
            ("Retry", true, { [weak self] in self?.retryLogin(id) }),
        ])
    }

    /// Retry: the same login as last time (the server's, or the one picked last).
    private func retryLogin(_ id: PaneID) {
        guard let retry = loginRetries[id] else { return }
        start(id, override: retry.override)
    }

    func pickLogin(_ id: PaneID) {
        guard var retry = loginRetries[id], let pane = pane(id), let server = pane.server else { return }
        retry.openPicker()
        loginRetries[id] = retry
        let keys = app.loginKeyOptions
        let users = PaneLoginRetry.users(current: retry.override?.username ?? server.username,
                                         quickUsers: TerminalPreferences.defaultQuickConnectUsers)
        let dialog = LoginRetryDialog(server: server.name, users: users, keys: keys, parent: window) { [weak self] user, choice in
            self?.chosen(id, username: user, choice: choice, keys: keys)
        } cancelled: { [weak self] in
            self?.loginRetries[id]?.closePicker()
        }
        dialog.present()
        if let user = ProcessInfo.processInfo.environment["RSSHTERM_TEST_LOGIN_USER"] {
            every(seconds: 3) { dialog.answerForTest(user: user); return false }
        }
    }

    /// The focused pane's bar: "Try Another Login…" (smoke test action).
    func pickLoginOnFocusedPane() {
        guard let id = model?.selectedTab.focused, loginRetries[id] != nil else { return }
        pickLogin(id)
    }

    /// "Save" on the focused pane's offer (smoke test action).
    func saveLoginOnFocusedPane() {
        guard let id = model?.selectedTab.focused, let offer = loginRetries[id]?.flow.saveOffer else { return }
        saveLogin(id, offer)
    }

    /// The bars' messages, for the smoke test.
    var loginBars: [String] { loginRetries.keys.compactMap { pane($0)?.barText } }

    private func chosen(_ id: PaneID, username: String, choice: PaneLoginRetry.Choice, keys: [PaneLoginRetry.KeyOption]) {
        guard var retry = loginRetries[id] else { return }
        guard let launch = retry.choose(username: username, choice: choice, keys: keys,
                                        keyDirectory: app.sshWriter.keyDirectory, markerDirectory: app.loginMarkerDirectory)
        else {
            toast("“\(username)” cannot be used as a user name.")
            retry.closePicker()
            loginRetries[id] = retry
            return
        }
        loginRetries[id] = retry
        if let key = launch.publicKey {
            try? FileManager.default.createDirectory(atPath: (key.path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: key.path, contents: Data(key.content.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
        start(id, override: launch.override)
    }

    private func start(_ id: PaneID, override: SSHLoginOverride?) {
        guard let pane = pane(id), let server = pane.server else { return }
        switch app.spawnPlan(for: .ssh(serverID: server.id), override: override) {
        case .success(let plan):
            pane.restart(plan)
            if let override { watchLogin(id, marker: override.markerFile) }
        case .failure(let error):
            toast(error.errorDescription ?? "\(error)")
        }
    }

    /// ssh touches the marker (LocalCommand) once logged in; the pane exiting first means it was refused again.
    private func watchLogin(_ id: PaneID, marker: String) {
        every(milliseconds: 300) { [weak self] in
            guard let self, let pane = pane(id) else { return false }
            if FileManager.default.fileExists(atPath: marker) {
                try? FileManager.default.removeItem(atPath: marker)
                loggedIn(id)
                return false
            }
            return !pane.exited
        }
    }

    private func loggedIn(_ id: PaneID) {
        guard var retry = loginRetries[id], let pane = pane(id) else { return }
        retry.loggedIn()
        loginRetries[id] = retry
        guard let offer = retry.flow.saveOffer else { return }
        pane.showBar(offer.message, buttons: [
            ("Not Now", false, { [weak self, weak pane] in
                self?.loginRetries[id]?.dismissSave()
                pane?.hideBar()
            }),
            ("Save", true, { [weak self] in self?.saveLogin(id, offer) }),
        ])
    }

    private func saveLogin(_ id: PaneID, _ offer: LoginSaveOffer) {
        run { [weak self] in
            guard let self else { return }
            do {
                try await app.saveLogin(offer)
                loginRetries[id]?.dismissSave()
                pane(id)?.hideBar()
                toast("Saved the login for \(pane(id)?.server?.name ?? "the server").")
            } catch {
                toast("Not saved: \(error.localizedDescription)")
            }
        }
    }
}

extension AppController {
    /// The vault keys the built-in agent holds, for the login picker.
    var loginKeyOptions: [PaneLoginRetry.KeyOption] {
        DesktopAgentKeys.load(vault?.credentials ?? []).keys.map(PaneLoginRetry.KeyOption.init)
    }

    /// Where ssh's LocalCommand leaves its "logged in" marker: next to the agent socket (a 0700 directory).
    var loginMarkerDirectory: String {
        let socket = agentSocket ?? AgentSocketPath.default(environment: environment, home: home)
        return (socket as NSString).deletingLastPathComponent
    }

    /// "Save" on the offer: the server gets the user and login that just worked.
    func saveLogin(_ offer: LoginSaveOffer) async throws {
        guard let document, case .updateServer(let serverID, _, let attempt) = offer else { return }
        try await document.commit(try document.vault.savingLogin(attempt, forServer: serverID))
    }
}
