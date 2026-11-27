import Foundation
import Testing
@testable import RSSHDesktopCore

@Suite struct SSHConnectionOptionsTests {
    @Test func defaultsBecomeSSHOptions() {
        let o = SSHConnectionOptions()
        #expect(o.keepAliveSeconds == 30)
        #expect(o.connectTimeoutSeconds == 15)
        #expect(o.autoReconnect)
        #expect(o.sshArguments == ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
                                   "-o", "ConnectTimeout=15"])
    }

    @Test func offValuesLeaveSSHAlone() {
        var o = SSHConnectionOptions()
        o.keepAliveSeconds = 0
        o.connectTimeoutSeconds = 0
        #expect(o.sshArguments.isEmpty)
    }

    @Test func valuesAreClampedAndOldJSONLoads() throws {
        var o = SSHConnectionOptions()
        o.keepAliveSeconds = 99_999
        o.connectTimeoutSeconds = -4
        let c = o.clamped()
        #expect(c.keepAliveSeconds == SSHConnectionOptions.keepAliveRange.upperBound)
        #expect(c.connectTimeoutSeconds == 0)
        let decoded = try JSONDecoder().decode(SSHConnectionOptions.self, from: Data(#"{"autoReconnect":false}"#.utf8))
        #expect(!decoded.autoReconnect)
        #expect(decoded.keepAliveSeconds == 30)
    }
}

@Suite struct ReconnectPolicyTests {
    @Test func reconnectsOnlyALostConnection() {
        let p = ReconnectPolicy()
        #expect(p.delay(exitStatus: 255, refusedLogin: false, attempt: 0, enabled: true) == 1)
        #expect(p.delay(exitStatus: 255, refusedLogin: false, attempt: 0, enabled: false) == nil)
        #expect(p.delay(exitStatus: 0, refusedLogin: false, attempt: 0, enabled: true) == nil) // logged out
        #expect(p.delay(exitStatus: 130, refusedLogin: false, attempt: 0, enabled: true) == nil)
        #expect(p.delay(exitStatus: 255, refusedLogin: true, attempt: 0, enabled: true) == nil)
    }

    @Test func backsOffThenGivesUp() {
        let p = ReconnectPolicy()
        let delays = (0..<p.maximumAttempts).compactMap { p.delay(exitStatus: 255, refusedLogin: false, attempt: $0, enabled: true) }
        #expect(delays == [1, 2, 5, 10, 20, 30])
        #expect(p.delay(exitStatus: 255, refusedLogin: false, attempt: p.maximumAttempts, enabled: true) == nil)
    }

    @Test func aLongSessionStartsCountingAgain() {
        let p = ReconnectPolicy()
        #expect(p.attemptAfter(previous: 4, connectedFor: 120) == 0)
        #expect(p.attemptAfter(previous: 4, connectedFor: 3) == 5)
    }
}

@Suite struct LongCommandTrackerTests {
    let pane = PaneID()
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func reportsAProgramThatRanLongEnough() {
        var t = LongCommandTracker()
        #expect(t.update(pane, foreground: ["make", "-j8"], at: t0) == nil)
        #expect(t.update(pane, foreground: ["make", "-j8"], at: t0 + 5) == nil)
        let done = t.update(pane, foreground: nil, at: t0 + 42)
        #expect(done == LongCommandTracker.Finished(pane: pane, command: "make -j8", seconds: 42))
        #expect(t.update(pane, foreground: nil, at: t0 + 50) == nil)
    }

    @Test func aDifferentProgramEndsThePreviousOne() {
        var t = LongCommandTracker()
        _ = t.update(pane, foreground: ["sleep", "30"], at: t0)
        let done = t.update(pane, foreground: ["vim"], at: t0 + 30)
        #expect(done?.command == "sleep 30")
        #expect(t.update(pane, foreground: nil, at: t0 + 31)?.command == "vim")
    }

    @Test func forgetDropsAClosedPane() {
        var t = LongCommandTracker()
        _ = t.update(pane, foreground: ["sleep", "30"], at: t0)
        t.forget(pane)
        #expect(t.update(pane, foreground: nil, at: t0 + 60) == nil)
    }

    @Test func notifiesOnlyWhenNotWatched() {
        let done = LongCommandTracker.Finished(pane: pane, command: "make", seconds: 42)
        #expect(LongCommandTracker.shouldNotify(done, threshold: 10, appActive: false, paneVisible: true))
        #expect(LongCommandTracker.shouldNotify(done, threshold: 10, appActive: true, paneVisible: false))
        #expect(!LongCommandTracker.shouldNotify(done, threshold: 10, appActive: true, paneVisible: true))
        #expect(!LongCommandTracker.shouldNotify(done, threshold: 60, appActive: false, paneVisible: false))
    }
}

@Suite struct TerminalCursorTests {
    @Test func stylesAndTitles() throws {
        #expect(TerminalCursorStyle.allCases == [.block, .bar, .underline])
        #expect(TerminalCursorStyle.bar.title == "Bar")
        #expect(try JSONDecoder().decode(TerminalCursorStyle.self, from: Data(#""underline""#.utf8)) == .underline)
    }
}
