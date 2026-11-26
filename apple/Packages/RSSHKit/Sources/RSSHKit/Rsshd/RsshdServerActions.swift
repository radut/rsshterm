import Foundation

/// One button on the server status sheet. The app shows the exact command and asks before running anything.
public enum RsshdServerAction: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case enable, installUser, installApt, copy, upgradeUser, upgradeApt, restart, linger, installReptyr
    }

    /// Start the daemon (run on an exec channel).
    case enable(command: String)
    /// install.sh --tarball for this user, no root (exec channel, output shown live).
    case installUser(command: String)
    /// The apt one-liner, typed into the terminal so the user answers sudo there.
    case installApt(typed: String)
    /// Commands to copy for anything else.
    case copy(text: String)
    /// A newer rsshd for a tarball install: install.sh again, then the daemon restarts (exec channel).
    case upgradeUser(command: String, to: String)
    /// A newer rsshd from apt, typed into the terminal (sudo).
    case upgradeApt(typed: String, to: String)
    /// The running daemon is older than the installed binary (installed by an upgrade, still the old one in memory):
    /// restart it so the new version runs. Sessions stay (tmux runs apart; KillMode=process).
    case restart(command: String, running: String, installed: String)
    /// Linger off: systemd stops rsshd and its sessions at the last logout (exec channel, no root when allowed).
    case linger(command: String)
    /// reptyr from apt, typed into the terminal (sudo).
    case installReptyr(typed: String)

    public var kind: Kind {
        switch self {
        case .enable: .enable
        case .installUser: .installUser
        case .installApt: .installApt
        case .copy: .copy
        case .upgradeUser: .upgradeUser
        case .upgradeApt: .upgradeApt
        case .restart: .restart
        case .linger: .linger
        case .installReptyr: .installReptyr
        }
    }

    public var id: Kind { kind }

    /// Typed into the terminal (sudo asks there) rather than run on an exec channel.
    public var isTyped: Bool {
        switch self {
        case .installApt, .upgradeApt, .installReptyr: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .enable: "Enable"
        case .installUser: "Install for this user (no root)"
        case .installApt: "Install from apt (.deb)"
        case .copy: "Copy commands"
        case .upgradeUser(_, let to), .upgradeApt(_, let to): "Upgrade rSshD to \(to)"
        case .restart(_, let running, let installed): "Restart to run rSshD \(installed) (still \(running); sessions stay)"
        case .linger: "Keep sessions after logout"
        case .installReptyr: "Install reptyr"
        }
    }

    /// The command as the confirm shows it.
    public var command: String {
        switch self {
        case .enable(let command), .installUser(let command), .upgradeUser(let command, _), .restart(let command, _, _),
             .linger(let command): command
        case .installApt(let typed), .upgradeApt(let typed, _), .installReptyr(let typed): typed
        case .copy(let text): text
        }
    }
}

public enum RsshdServerActions {
    /// Also linger (as install.sh does), so the sessions survive the last logout; a refused linger does not fail it.
    static let enableSystemd = #"systemctl --user enable --now rsshd && { loginctl enable-linger "$(id -un)" || true; }"#
    static let enableLaunchd = #"launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/dev.rssh.rsshd.plist""#
    /// `rsshd rpc` starts the daemon when none runs; with stdin closed it then exits.
    static let enableByRPC = "sh -c '\(RsshdCommands.path); rsshd rpc </dev/null >/dev/null'"

    /// Restarts the user's daemon wherever it runs, so the installed binary is the one running; the tmux server and its
    /// sessions stay. A daemon that `rsshd rpc` started by itself (no systemd unit or launchd job running it) is
    /// stopped with SIGTERM and started again by `rsshd rpc`: `systemctl try-restart` alone exits 0 for an inactive
    /// unit and left that daemon on the old version. `[r]sshd` keeps pkill from matching this very sh -c line.
    static let restartDaemon = "sh -c '\(RsshdCommands.path); "
        + "if systemctl --user is-active -q rsshd 2>/dev/null; then systemctl --user restart rsshd; "
        + "elif launchctl print \"gui/$(id -u)/dev.rssh.rsshd\" >/dev/null 2>&1; "
        + "then launchctl kickstart -k \"gui/$(id -u)/dev.rssh.rsshd\"; "
        + "else pkill -TERM -u \"$(id -u)\" -f \"[r]sshd serve\"; sleep 1; rsshd rpc </dev/null >/dev/null; fi'"
    static let lingerCommand = #"loginctl enable-linger "$(id -un)""#
    /// The leading space keeps typed commands out of shell history where HISTCONTROL ignores such lines.
    static let upgradeAptTyped = " sudo apt-get update && sudo apt-get install -y rsshd && " + restartDaemon
    static let reptyrTyped = " sudo apt-get install -y reptyr"

    /// What the sheet offers for `probe`: the install choices when rsshd is missing, Enable when it is installed but
    /// stopped; while it runs, whatever would make it better (a newer version, a restart onto the installed one,
    /// linger, reptyr). `running` is the version the daemon itself reports (`hello`), when known.
    public static func actions(for probe: RsshdServerProbe, running: String? = nil) -> [RsshdServerAction] {
        guard probe.isInstalled else {
            var actions: [RsshdServerAction] = [.installUser(command: RsshdInstall.userInstallCommand)]
            if probe.os == "linux", probe.hasApt { actions.append(.installApt(typed: RsshdInstall.aptTyped)) }
            actions.append(.copy(text: RsshdInstall.copyText))
            return actions
        }
        guard let doctor = probe.doctor else { return [] }
        guard doctor.check("daemon")?.ok == false else { return upkeep(probe, doctor, running: running) }
        let unitOK = doctor.check("service-unit")?.ok ?? false
        let os = doctor.os.isEmpty ? probe.os : doctor.os
        switch (os, unitOK) {
        case ("linux", true): return [.enable(command: enableSystemd)]
        case ("darwin", true): return [.enable(command: enableLaunchd)]
        default: return [.enable(command: enableByRPC)]
        }
    }

    /// The sheet's all-clear, when nothing is left to offer: "Everything checked: rsshd 0.1.1 (latest) running, sessions
    /// survive logout, reptyr ready." Nil while an action is still offered or a required piece is missing.
    public static func allClear(for probe: RsshdServerProbe, running: String? = nil) -> String? {
        guard probe.isInstalled, let doctor = probe.doctor, doctor.missing.isEmpty,
              doctor.check("daemon")?.ok != false, actions(for: probe, running: running).isEmpty else { return nil }
        let version = running ?? doctor.version
        var parts = ["rSshD \(version)" + (RsshdRelease.isOlder(version) ? "" : " (latest)") + " running"]
        if doctor.check("linger")?.ok == true { parts.append("sessions survive logout") }
        if doctor.check("reptyr")?.ok == true { parts.append("reptyr ready") }
        return "Everything checked: " + parts.joined(separator: ", ") + "."
    }

    private static func upkeep(_ probe: RsshdServerProbe, _ doctor: RsshdDoctorReport, running: String?)
        -> [RsshdServerAction] {
        var actions: [RsshdServerAction] = []
        let installed = doctor.version
        let os = doctor.os.isEmpty ? probe.os : doctor.os
        if RsshdRelease.isOlder(installed) {
            actions.append(probe.isFromApt
                ? .upgradeApt(typed: upgradeAptTyped, to: RsshdRelease.latest)
                : .upgradeUser(command: RsshdInstall.userInstallCommand + " && " + restartDaemon, to: RsshdRelease.latest))
        } else if let running, RsshdRelease.isOlder(running, than: installed) {
            actions.append(.restart(command: restartDaemon, running: running, installed: installed))
        }
        if os == "linux", doctor.check("linger")?.ok == false { actions.append(.linger(command: lingerCommand)) }
        if os == "linux", probe.hasApt, doctor.check("reptyr")?.ok == false {
            actions.append(.installReptyr(typed: reptyrTyped))
        }
        return actions
    }
}

/// install.sh, as published next to the releases.
public enum RsshdInstall {
    public static let scriptURL = "https://rssh-ea902a.gitlab.io/install.sh"
    /// Printed by `userInstallCommand` when install.sh itself cannot be fetched.
    static let downloadFailedMarker = "rsshd-install: download failed"

    /// Fetches install.sh to a temp file and runs it in tarball mode (signature-checked, ~/.local/bin, user service).
    public static let userInstallCommand = "sh -c 'f=$(mktemp) || exit 1; "
        + "{ curl -fsSL \"\(scriptURL)\" -o \"$f\" 2>/dev/null || wget -qO \"$f\" \"\(scriptURL)\" 2>/dev/null; } "
        + "|| { echo \"\(downloadFailedMarker)\"; rm -f \"$f\"; exit 3; }; "
        + "sh \"$f\" --tarball; s=$?; rm -f \"$f\"; exit $s'"

    /// install.sh's own one-liner (apt on Debian/Ubuntu asks sudo, so it runs where the user can type).
    public static let aptTyped = "curl -fsSLO \(scriptURL) && sh install.sh"

    public static let copyText = """
        # Read it, then run it (apt on Debian/Ubuntu, otherwise a signed tarball to ~/.local/bin):
        curl -fsSLO \(scriptURL) && less install.sh && sh install.sh
        # Without root on any Linux or macOS:
        sh install.sh --tarball
        """

    /// A sentence for a failed install, or nil when it worked.
    public static func explain(exitStatus: Int, output: String) -> String? {
        guard exitStatus != 0 else { return nil }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        if lines.contains(downloadFailedMarker) {
            return "Could not download \(scriptURL). The download site may not be public yet."
        }
        if let line = lines.last(where: { $0.contains("download failed: ") }),
           let range = line.range(of: "download failed: ") {
            return "Could not download \(line[range.upperBound...]). The download site may not be public yet."
        }
        let last = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return "The install stopped (exit status \(exitStatus))" + (last.isEmpty ? "." : ": \(last)")
    }
}
