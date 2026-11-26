import Foundation
import Testing
@testable import RSSHTermLinux

@Suite struct AppSettingsTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)/desktop.json")
    }

    @Test func defaults() {
        let s = AppSettings()
        #expect(s.fontName == "Monospace 11")
        #expect(s.colorScheme == .system)
        #expect(s.scrollbackLines == 10_000)
        #expect(s.autoInstallUpdates)
        #expect(!s.includeOffered)
        #expect(s.lastUpdateCheck == nil)
        #expect(s.broadcastIndicator)
    }

    @Test func roundTripAndOwnerOnly() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var s = AppSettings()
        s.fontName = "DejaVu Sans Mono 13"
        s.colorScheme = .dark
        s.scrollbackLines = 50_000
        s.includeOffered = true
        s.broadcastIndicator = false
        s.restoreSession = false
        s.lastUpdateCheck = Date(timeIntervalSince1970: 1_800_000_000)
        try s.save(to: file)
        #expect(AppSettings.load(from: file) == s)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func missingOrBrokenFileGivesDefaults() throws {
        let file = tempFile()
        #expect(AppSettings.load(from: file) == AppSettings())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("{nope".utf8).write(to: file)
        #expect(AppSettings.load(from: file) == AppSettings())
    }

    @Test func unknownAndPartialKeysKeepDefaults() throws {
        let json = #"{"fontName":"Hack 10","colorScheme":"neon","scrollbackLines":-5,"future":1}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.fontName == "Hack 10")
        #expect(s.colorScheme == .system)
        #expect(s.scrollbackLines == 0)
        #expect(s.autoInstallUpdates)
    }

    @Test func scrollbackIsClamped() {
        var s = AppSettings()
        s.scrollbackLines = 99_000_000
        #expect(s.scrollbackLines == AppSettings.maximumScrollback)
    }

    @Test func defaultPathFollowsXDG() {
        #expect(AppSettings.defaultURL(environment: ["XDG_CONFIG_HOME": "/x"], home: "/h").path == "/x/rssh/desktop.json")
        #expect(AppSettings.defaultURL(environment: [:], home: "/h").path == "/h/.config/rssh/desktop.json")
    }
}
