import Foundation
import Testing
@testable import RSSHKit

@Suite struct QuickConnectUsersTests {
    @Test func defaultsAreRootAndUbuntu() {
        #expect(TerminalPreferences().quickConnectUsers == ["root", "ubuntu"])
        #expect(TerminalPreferences().orderedQuickConnectUsers == ["root", "ubuntu"])
    }

    @Test func lastUsedComesFirstEvenWhenTypedOnce() {
        let p = TerminalPreferences().usingQuickConnectUser("ubuntu")
        #expect(p.orderedQuickConnectUsers == ["ubuntu", "root"])
        #expect(p.usingQuickConnectUser("deploy").orderedQuickConnectUsers == ["deploy", "root", "ubuntu"])
    }

    @Test func listIsCleaned() {
        let p = TerminalPreferences(quickConnectUsers: [" admin ", "", "admin", "a b", "pi"])
        #expect(p.quickConnectUsers == ["admin", "pi"])
        #expect(p.addingQuickConnectUser("pi").quickConnectUsers == ["admin", "pi"])
        #expect(p.addingQuickConnectUser("ec2-user").quickConnectUsers == ["admin", "pi", "ec2-user"])
        var edited = p
        edited.quickConnectUsers.append("  ")
        #expect(edited.quickConnectUsers == ["admin", "pi"])
    }

    @Test func persistsAndOldSettingsGetTheDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "rssh-quick-users-\(UUID().uuidString)"))
        let store = TerminalPreferencesStore(defaults: defaults)
        let p = TerminalPreferences(quickConnectUsers: ["admin"]).usingQuickConnectUser("admin")
        store.save(p)
        #expect(store.load() == p)
        defaults.set(Data(#"{"fontSize":15}"#.utf8), forKey: TerminalPreferencesStore.key)
        #expect(store.load().quickConnectUsers == ["root", "ubuntu"])
        #expect(store.load().lastQuickConnectUser == nil)
    }
}
