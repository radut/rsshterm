import Foundation
import Testing
@testable import RSSHTermLinux

@Suite struct SSHIncludeTests {
    let line = "Include ~/.config/rssh/ssh_config"

    @Test func detectsTheIncludeInItsCommonSpellings() {
        let home = "/home/u"
        let generated = "/home/u/.config/rssh/ssh_config"
        func has(_ text: String) -> Bool { SSHInclude.isInstalled(in: text, configPath: generated, home: home) }
        #expect(has("Include ~/.config/rssh/ssh_config\nHost x\n"))
        #expect(has("  include   /home/u/.config/rssh/ssh_config\n"))
        #expect(has("Include=\"~/.config/rssh/ssh_config\"\n"))
        #expect(!has("# Include ~/.config/rssh/ssh_config\n"))
        #expect(!has("Host a\n  Include ~/.config/rssh/ssh_config\n")) // inside a Host block it only applies there
        #expect(!has(""))
    }

    @Test func insertsAtTheTopAboveHostBlocks() {
        let text = "# mine\nHost a\n  User b\n"
        let out = SSHInclude.adding(to: text, configPath: "/home/u/.config/rssh/ssh_config", home: "/home/u")
        #expect(out.hasPrefix("# Added by rSshTerm: vault servers as ssh hosts\n\(line)\n\n# mine\nHost a"))
        #expect(SSHInclude.isInstalled(in: out, configPath: "/home/u/.config/rssh/ssh_config", home: "/home/u"))
    }

    @Test func pathOutsideHomeIsWrittenAbsolute() {
        let out = SSHInclude.adding(to: "", configPath: "/xdg/rssh/ssh_config", home: "/home/u")
        #expect(out.contains("Include \"/xdg/rssh/ssh_config\"\n"))
    }

    @Test func installWritesOwnerOnlyFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.path
        let generated = "\(home)/.config/rssh/ssh_config"
        try SSHInclude.install(home: home, configPath: generated)
        let config = "\(home)/.ssh/config"
        let text = try String(contentsOfFile: config, encoding: .utf8)
        #expect(text.contains(line))
        let attrs = try FileManager.default.attributesOfItem(atPath: config)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: "\(home)/.ssh")
        #expect((dirAttrs[.posixPermissions] as? Int) == 0o700)
        // twice is a no-op
        try SSHInclude.install(home: home, configPath: generated)
        #expect(try String(contentsOfFile: config, encoding: .utf8) == text)
    }
}
