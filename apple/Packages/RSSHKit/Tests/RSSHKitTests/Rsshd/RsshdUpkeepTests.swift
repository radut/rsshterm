import Foundation
import Testing
@testable import RSSHKit

@Suite struct RsshdReleaseTests {
    @Test func comparesNumerically() {
        #expect(RsshdRelease.isOlder("0.1.0", than: "0.1.1"))
        #expect(RsshdRelease.isOlder("0.9.9", than: "0.10.0"))
        #expect(RsshdRelease.isOlder("v0.1", than: "0.1.1"))
        #expect(!RsshdRelease.isOlder("0.1.1", than: "0.1.1"))
        #expect(!RsshdRelease.isOlder("1.0.0", than: "0.1.1"))
        #expect(!RsshdRelease.isOlder("0.1.1-rc1", than: "0.1.1"))
    }

    @Test func unknownVersionsAreNeverOld() {
        #expect(!RsshdRelease.isOlder("dev"))
        #expect(!RsshdRelease.isOlder(""))
        #expect(!RsshdRelease.isOlder("0.1.0", than: "dev"))
    }

    @Test func theAttachChipMentionsAnUpdate() {
        let old = RsshdAttachment(id: "a", backend: "tmux", hello: hello("0.0.1"), created: true)
        #expect(old.summary.hasSuffix(" · update \(RsshdRelease.latest)"))
        let current = RsshdAttachment(id: "a", backend: "tmux", hello: hello(RsshdRelease.latest), created: true)
        #expect(!current.summary.contains("update"))
    }

    private func hello(_ version: String) -> RsshdHello {
        let json = #"{"proto":1,"version":"\#(version)","backends":{"tmux":"3.4"}}"#
        return try! JSONDecoder().decode(RsshdHello.self, from: Data(json.utf8))
    }
}

@Suite struct RsshdUpkeepActionsTests {
    /// A running daemon of `version`, with these checks failing.
    private func probe(_ path: String, version: String, failing: [String] = [], apt: Bool = true) -> RsshdServerProbe {
        let checks = (["daemon", "service-unit", "tmux", "linger", "reptyr"]).map { name in
            #"{"name":"\#(name)","ok":\#(!failing.contains(name))}"#
        }.joined(separator: ",")
        let json = #"{"version":"\#(version)","missing":[],"report":{"os":"linux","checks":[\#(checks)]}}"#
        return RsshdServerProbe.parse("uname:Linux\n" + (apt ? "apt:yes\n" : "") + "rsshd:\(path)\n" + json)
    }

    @Test func upToDateAndCompleteOffersNothing() {
        #expect(RsshdServerActions.actions(for: probe("/usr/bin/rsshd", version: RsshdRelease.latest)).isEmpty)
    }

    @Test func olderDebIsUpgradedWithAptInTheTerminal() {
        let actions = RsshdServerActions.actions(for: probe("/usr/bin/rsshd", version: "0.0.1"))
        #expect(actions.map(\.kind) == [.upgradeApt])
        #expect(actions[0].isTyped)
        #expect(actions[0].command.contains("apt-get install -y rsshd"))
        #expect(actions[0].command.hasSuffix(RsshdServerActions.restartDaemon))
        #expect(actions[0].title == "Upgrade rSshD to \(RsshdRelease.latest)")
    }

    @Test func olderTarballIsUpgradedByInstallShThenRestarted() {
        let actions = RsshdServerActions.actions(for: probe("/home/u/.local/bin/rsshd", version: "0.0.1"))
        #expect(actions.map(\.kind) == [.upgradeUser])
        #expect(!actions[0].isTyped)
        #expect(actions[0].command.hasPrefix(RsshdInstall.userInstallCommand))
        #expect(actions[0].command.hasSuffix(RsshdServerActions.restartDaemon))
    }

    @Test func aDaemonOlderThanItsBinaryIsRestarted() {
        let actions = RsshdServerActions.actions(for: probe("/usr/bin/rsshd", version: RsshdRelease.latest), running: "0.0.1")
        #expect(actions.map(\.kind) == [.restart])
        #expect(actions[0].title == "Restart to run rSshD \(RsshdRelease.latest) (still 0.0.1; sessions stay)")
    }

    /// `try-restart` alone is a no-op for a daemon `rsshd rpc` started outside systemd: that one is stopped and
    /// started again, and the pattern cannot match the restart command's own sh -c line.
    @Test func restartAlsoReplacesADaemonStartedByRPC() {
        let command = RsshdServerActions.restartDaemon
        #expect(command.contains("systemctl --user is-active -q rsshd"))
        #expect(command.contains(#"pkill -TERM -u "$(id -u)" -f "[r]sshd serve""#))
        #expect(command.contains("rsshd rpc </dev/null"))
        #expect(!command.contains("try-restart"))
    }

    @Test func lingerAndReptyrAreOffered() {
        let actions = RsshdServerActions.actions(for: probe("/usr/bin/rsshd", version: RsshdRelease.latest,
                                                            failing: ["linger", "reptyr"]))
        #expect(actions.map(\.kind) == [.linger, .installReptyr])
        #expect(actions[0].command == #"loginctl enable-linger "$(id -un)""#)
        #expect(!actions[0].isTyped && actions[1].isTyped)
    }

    @Test func reptyrNeedsApt() {
        let actions = RsshdServerActions.actions(for: probe("/home/u/.local/bin/rsshd", version: RsshdRelease.latest,
                                                            failing: ["reptyr"], apt: false))
        #expect(actions.isEmpty)
    }

    @Test func allClearOnceNothingIsLeftToDo() {
        let done = probe("/usr/bin/rsshd", version: RsshdRelease.latest)
        #expect(RsshdServerActions.allClear(for: done, running: RsshdRelease.latest)
            == "Everything checked: rSshD \(RsshdRelease.latest) (latest) running, sessions survive logout, reptyr ready.")
        // Still on the old daemon: the Restart button shows, no all-clear.
        #expect(RsshdServerActions.allClear(for: done, running: "0.0.1") == nil)
        #expect(RsshdServerActions.allClear(for: probe("/usr/bin/rsshd", version: "0.0.1")) == nil)
        let noLinger = probe("/home/u/.local/bin/rsshd", version: RsshdRelease.latest, failing: ["linger"], apt: false)
        #expect(RsshdServerActions.allClear(for: noLinger) == nil)
    }

    @Test func eachActionHasItsOwnID() {
        let actions = RsshdServerActions.actions(for: probe("/usr/bin/rsshd", version: "0.0.1", failing: ["linger", "reptyr"]))
        #expect(Set(actions.map(\.id)).count == actions.count)
    }
}
