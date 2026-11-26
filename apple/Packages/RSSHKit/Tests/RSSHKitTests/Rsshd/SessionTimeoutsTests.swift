import Foundation
import Testing
@testable import RSSHKit

@Suite struct SessionTimeoutsTests {
    private func args(_ data: Data) throws -> [String: Any] {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["args"] as? [String: Any])
    }

    @Test func defaultHoldsADayIdleAndAWeekInAnyCase() {
        #expect(SessionTimeouts.standard == SessionTimeouts(idleSeconds: 86_400, hardSeconds: 604_800))
        #expect(TerminalPreferences().sessionTimeouts == .standard)
    }

    @Test func createSendsTimeoutsInSeconds() throws {
        let timeouts = SessionTimeouts(idleSeconds: 86_400, hardSeconds: 0)
        let data = try RsshdCodec.request(id: 1, op: "create",
                                          args: RsshdCreateArgs(backend: "tmux", timeouts: timeouts))
        let sent = try args(data)
        let limits = try #require(sent["timeouts"] as? [String: Any])
        #expect(limits["idle_s"] as? Int == 86_400)
        #expect(limits["hard_s"] as? Int == 0)
        #expect(limits["id"] == nil)
    }

    @Test func setTimeoutsNamesTheSession() throws {
        let data = try RsshdCodec.request(id: 2, op: "set_timeouts",
                                          args: RsshdTimeoutArgs(id: "abc", SessionTimeouts(idleSeconds: 3600, hardSeconds: 7200)))
        let sent = try args(data)
        #expect(sent["id"] as? String == "abc")
        #expect(sent["idle_s"] as? Int == 3600)
        #expect(sent["hard_s"] as? Int == 7200)
    }

    @Test func valuesStayInsideWhatTheDaemonTakes() {
        let t = SessionTimeouts(idleSeconds: -5, hardSeconds: 10 * 365 * 86_400)
        #expect(t.idleSeconds == 0)
        #expect(t.hardSeconds == SessionTimeouts.maxSeconds)
    }

    @Test func titles() {
        #expect(SessionTimeouts.title(0) == "Never")
        #expect(SessionTimeouts.title(3600) == "1 hour")
        #expect(SessionTimeouts.title(8 * 3600) == "8 hours")
        #expect(SessionTimeouts.title(86_400) == "1 day")
        #expect(SessionTimeouts.title(3 * 86_400) == "3 days")
        #expect(SessionTimeouts.title(90) == "1 minute")
    }

    @Test func aServerSetValueJoinsTheChoicesInOrder() {
        let choices = SessionTimeouts.choices(including: 2 * 3600)
        #expect(choices.contains(2 * 3600))
        #expect(choices.last == 0)
        #expect(Array(choices.dropLast()) == Array(choices.dropLast()).sorted())
        #expect(SessionTimeouts.choices(including: 86_400) == SessionTimeouts.choices)
    }

    @Test func oldSavedPreferencesGetTheDefault() throws {
        let saved = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"fontSize":14}"#.utf8))
        #expect(saved.sessionTimeouts == .standard)
        let round = try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(
            TerminalPreferences(sessionTimeouts: SessionTimeouts(idleSeconds: 3600, hardSeconds: 0))))
        #expect(round.sessionTimeouts == SessionTimeouts(idleSeconds: 3600, hardSeconds: 0))
    }
}
