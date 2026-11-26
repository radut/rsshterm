import Foundation
import Testing
@testable import RSSHKit

@Suite struct SessionDaemonPolicyTests {
    @Test func serverOverrideWins() {
        #expect(SessionDaemonPolicy.backend(server: .screen, global: .tmux) == .screen)
        #expect(SessionDaemonPolicy.backend(server: .off, global: .tmux) == .off)
        #expect(SessionDaemonPolicy.backend(server: .tmux, global: .off) == .tmux)
    }

    @Test func noOverrideTakesTheGlobalDefault() {
        #expect(SessionDaemonPolicy.backend(server: nil, global: .tmux) == .tmux)
        #expect(SessionDaemonPolicy.backend(server: nil, global: .off) == .off)
    }

    @Test func defaultsAreTmux() {
        #expect(TerminalPreferences().sessionBackend == .tmux)
    }

    @Test func oldPreferencesDecodeWithTmux() throws {
        let prefs = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"fontSize":14}"#.utf8))
        #expect(prefs.sessionBackend == .tmux)
    }

    @Test func oldServerDecodesAsUseDefault() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"a","host":"h","port":22,"username":"u"}"#
        let server = try JSONDecoder().decode(Server.self, from: Data(json.utf8))
        #expect(server.sessionDaemon == nil)
        #expect(server.lastSessionBackend == nil)
    }

    @Test func unknownOverrideDecodesAsUseDefault() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"a","host":"h","port":22,"username":"u","sessionDaemon":"zellij"}"#
        let server = try JSONDecoder().decode(Server.self, from: Data(json.utf8))
        #expect(server.sessionDaemon == nil)
    }

    @Test func overrideAndLastBackendRoundTrip() throws {
        var server = Server(name: "a", host: "h", username: "u")
        server.sessionDaemon = .screen
        server.lastSessionBackend = "screen"
        let back = try JSONDecoder().decode(Server.self, from: JSONEncoder().encode(server))
        #expect(back == server)
    }

    @Test func draftKeepsTheOverride() throws {
        var server = Server(name: "a", host: "h", username: "u")
        server.sessionDaemon = .off
        server.lastSessionBackend = "tmux"
        let made = try ServerDraft(server: server).makeServer(id: server.id)
        #expect(made.sessionDaemon == .off)
    }

    @Test func lastBackendIsRememberedOnlyWhenItChanges() {
        var server = Server(name: "a", host: "h", username: "u")
        #expect(server.rememberingSessionBackend("tmux")?.lastSessionBackend == "tmux")
        server.lastSessionBackend = "tmux"
        #expect(server.rememberingSessionBackend("tmux") == nil)
    }
}

@Suite struct RsshdBackendRowsTests {
    private func hello(_ backends: [String: String], missing: [String] = []) -> RsshdHello {
        RsshdHello(proto: 1, version: "1.0.0", backends: backends, defaultBackend: "tmux",
                   caps: .init(os: "linux"), missing: missing)
    }

    @Test func backendTheServerLacksIsDisabledWithWhy() {
        let rows = RsshdBackendRow.rows(hello: hello(["tmux": "3.4"], missing: ["screen"]))
        #expect(rows == [
            RsshdBackendRow(backend: .tmux, version: "3.4", why: nil),
            RsshdBackendRow(backend: .screen, version: nil, why: "screen is not installed on the server"),
        ])
    }

    @Test func backendTheDaemonDoesNotOfferSaysSo() {
        let rows = RsshdBackendRow.rows(hello: hello(["tmux": "3.4"]))
        #expect(rows[1].why == "this rSshD has no screen backend")
        #expect(!rows[1].isAvailable)
    }

    @Test func bothAvailable() {
        let rows = RsshdBackendRow.rows(hello: hello(["tmux": "3.4", "screen": "4.09"]))
        #expect(rows.filter(\.isAvailable).count == 2)
    }
}

@Suite struct RsshdServerProbeTests {
    private let doctorJSON = """
    {
      "version": "1.0.2",
      "healthy": false,
      "missing": ["daemon"],
      "report": {
        "os": "linux",
        "tmux_version": "3.4",
        "checks": [
          {"name": "tmux", "ok": true, "required": true, "detail": "tmux 3.4"},
          {"name": "service-unit", "ok": true, "required": true, "detail": "/usr/lib/systemd/user/rsshd.service"},
          {"name": "daemon", "ok": false, "required": true, "detail": "no daemon", "fix": "systemctl --user enable --now rsshd"}
        ]
      }
    }
    """

    @Test func parsesTheCheckScriptOutput() throws {
        let probe = RsshdServerProbe.parse("uname:Linux\napt:yes\nrsshd:/usr/bin/rsshd\n" + doctorJSON)
        #expect(probe.os == "linux" && probe.hasApt && probe.rsshdPath == "/usr/bin/rsshd")
        let doctor = try #require(probe.doctor)
        #expect(doctor.version == "1.0.2" && doctor.missing == ["daemon"])
        #expect(doctor.check("daemon")?.ok == false)
        #expect(doctor.check("service-unit")?.ok == true)
    }

    @Test func notInstalled() {
        let probe = RsshdServerProbe.parse("uname:Darwin\n")
        #expect(probe.os == "darwin" && !probe.hasApt && probe.rsshdPath == nil && probe.doctor == nil)
    }

    @Test func enableOnLinuxWithAUnitIsSystemctl() {
        let probe = RsshdServerProbe.parse("uname:Linux\nrsshd:/usr/bin/rsshd\n" + doctorJSON)
        let actions = RsshdServerActions.actions(for: probe)
        #expect(actions == [.enable(command: #"systemctl --user enable --now rsshd && { loginctl enable-linger "$(id -un)" || true; }"#)])
    }

    @Test func enableOnMacIsLaunchctl() {
        let json = #"{"version":"1.0.2","missing":["daemon"],"report":{"os":"darwin","checks":[{"name":"service-unit","ok":true},{"name":"daemon","ok":false}]}}"#
        let probe = RsshdServerProbe.parse("uname:Darwin\nrsshd:/Users/u/.local/bin/rsshd\n" + json)
        #expect(RsshdServerActions.actions(for: probe) ==
                [.enable(command: #"launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/dev.rssh.rsshd.plist""#)])
    }

    @Test func enableWithoutAUnitStartsItThroughRPC() {
        let json = #"{"version":"1.0.2","missing":["service-unit","daemon"],"report":{"os":"linux","checks":[{"name":"service-unit","ok":false},{"name":"daemon","ok":false}]}}"#
        let probe = RsshdServerProbe.parse("uname:Linux\nrsshd:/home/u/.local/bin/rsshd\n" + json)
        guard case .enable(let command) = RsshdServerActions.actions(for: probe).first else {
            Issue.record("no enable"); return
        }
        #expect(command.contains("rsshd rpc </dev/null"))
    }

    @Test func healthyServerNeedsNothing() {
        let json = #"{"version":"1.0.2","missing":[],"report":{"os":"linux","checks":[{"name":"daemon","ok":true}]}}"#
        #expect(RsshdServerActions.actions(for: RsshdServerProbe.parse("uname:Linux\nrsshd:/usr/bin/rsshd\n" + json)).isEmpty)
    }

    @Test func notInstalledOnDebianOffersAllThree() {
        let actions = RsshdServerActions.actions(for: RsshdServerProbe.parse("uname:Linux\napt:yes\n"))
        #expect(actions.map(\.kind) == [.installUser, .installApt, .copy])
        guard case .installApt(let typed) = actions[1] else { return }
        #expect(typed == "curl -fsSLO \(RsshdInstall.scriptURL) && sh install.sh")
    }

    @Test func notInstalledOnMacHasNoApt() {
        let actions = RsshdServerActions.actions(for: RsshdServerProbe.parse("uname:Darwin\n"))
        #expect(actions.map(\.kind) == [.installUser, .copy])
    }

    @Test func userInstallDownloadsAndRunsTarballMode() {
        let command = RsshdInstall.userInstallCommand
        #expect(command.contains(RsshdInstall.scriptURL))
        #expect(command.contains("--tarball"))
        #expect(!command.contains("sudo"))
    }

    @Test func downloadFailureIsExplained() {
        let message = RsshdInstall.explain(exitStatus: 3, output: "rsshd-install: download failed\n")
        #expect(message == "Could not download \(RsshdInstall.scriptURL). The download site may not be public yet.")
        let inner = RsshdInstall.explain(exitStatus: 1, output: "rsshd: error: download failed: https://x/releases/1/a.tgz\n")
        #expect(inner == "Could not download https://x/releases/1/a.tgz. The download site may not be public yet.")
    }

    @Test func otherFailureShowsTheLastLine() {
        #expect(RsshdInstall.explain(exitStatus: 1, output: "a\nrsshd: error: needs curl or wget\n")
                == "The install stopped (exit status 1): rsshd: error: needs curl or wget")
        #expect(RsshdInstall.explain(exitStatus: 0, output: "ok") == nil)
    }
}

@Suite struct RsshdCommandsTests {
    @Test func attachIsTypedWithALeadingSpaceAndExec() throws {
        let typed = try #require(RsshdCommands.typedAttach(id: "5e55a0b1"))
        #expect(typed.hasPrefix(" exec sh -c '"))
        #expect(typed.hasSuffix("exec rsshd attach 5e55a0b1'\r"))
    }

    @Test func unsafeIDsAreRefused() {
        #expect(RsshdCommands.typedAttach(id: "a'b") == nil)
        #expect(RsshdCommands.typedAttach(id: "") == nil)
        #expect(RsshdCommands.typedAttach(id: "a b") == nil)
    }

    @Test func foreignAttachIsQuoted() {
        #expect(RsshdCommands.typedForeign(["tmux", "attach", "-t", "it's"]) ==
                #" exec 'tmux' 'attach' '-t' 'it'\''s'"# + "\r")
        #expect(RsshdCommands.typedForeign([]) == nil)
    }

    @Test func rpcExitsWith127WhenMissing() {
        #expect(RsshdCommands.rpc.contains("exit 127"))
        #expect(RsshdCommands.rpc.contains("exec rsshd rpc"))
    }
}

@Suite struct RsshdChipThrottleTests {
    @Test func missingChipShowsOncePerDay() {
        let morning = Date(timeIntervalSince1970: 1_795_500_000)
        #expect(RsshdChipThrottle.shouldShowMissing(lastShown: nil, now: morning))
        #expect(!RsshdChipThrottle.shouldShowMissing(lastShown: morning, now: morning.addingTimeInterval(3600)))
        #expect(RsshdChipThrottle.shouldShowMissing(lastShown: morning, now: morning.addingTimeInterval(86_400)))
    }
}
