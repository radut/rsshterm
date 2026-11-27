import Foundation
import RSSHDesktopCore
import Testing
@testable import RSSHTermLinux

/// gsettings and xdg-mime in memory: the tests never change the desktop's settings.
final class FakeDesktopTools: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private(set) var calls: [[String]] = []
    let hasSchema: Bool

    init(hasSchema: Bool, values: [String: String] = [:]) {
        self.hasSchema = hasSchema
        self.values = values
    }

    func value(_ key: String) -> String? { lock.withLock { values[key] } }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessOutput {
        lock.withLock {
            calls.append([executable] + arguments)
            switch arguments.first {
            case "list-schemas":
                return ProcessOutput(status: 0, output: hasSchema ? "org.gnome.desktop.interface\n\(LinuxDefaultTerminal.gnomeSchema)\n" : "x\n")
            case "get": return ProcessOutput(status: 0, output: (values[arguments[2]] ?? "''") + "\n")
            case "set": values[arguments[2]] = arguments[3]; return ProcessOutput(status: 0, output: "")
            case "reset": values[arguments[2]] = nil; return ProcessOutput(status: 0, output: "")
            case "query": return ProcessOutput(status: 0, output: (values["ssh"] ?? "") + "\n")
            case "default": values["ssh"] = arguments[1]; return ProcessOutput(status: 0, output: "")
            default: return ProcessOutput(status: 1, output: "")
            }
        }
    }

    func launchDetached(_ executable: String, _ arguments: [String]) throws {}
}

@Suite struct DefaultTerminalListTests {
    @Test func preferringPutsRSSHTermFirstAndKeepsTheRest() {
        let text = "# my terminals\norg.gnome.Ptyxis.desktop\nkitty.desktop\n"
        let out = LinuxDefaultTerminal.preferring(in: text)
        #expect(out == "# my terminals\ndev.rsshterm.RSSHTerm.desktop\norg.gnome.Ptyxis.desktop\nkitty.desktop\n")
        #expect(LinuxDefaultTerminal.isPreferred(in: out))
        #expect(!LinuxDefaultTerminal.isPreferred(in: text))
    }

    @Test func preferringMovesAnOlderLineInsteadOfDoublingIt() {
        let out = LinuxDefaultTerminal.preferring(in: "kitty.desktop\ndev.rsshterm.RSSHTerm.desktop:new-window\n")
        #expect(LinuxDefaultTerminal.entries(out) == ["dev.rsshterm.RSSHTerm.desktop", "kitty.desktop"])
    }

    @Test func noListYet() {
        #expect(LinuxDefaultTerminal.preferring(in: nil) == "dev.rsshterm.RSSHTerm.desktop\n")
        #expect(LinuxDefaultTerminal.preferring(in: "# only a comment\n") == "# only a comment\ndev.rsshterm.RSSHTerm.desktop\n")
    }

    @Test func desktopSpecificListsThatExistComeFirst() {
        let t = LinuxDefaultTerminal(environment: ["XDG_CONFIG_HOME": "/c", "XDG_CURRENT_DESKTOP": "ubuntu:GNOME", "PATH": "/nonexistent"],
                                     home: "/h", runner: FakeDesktopTools(hasSchema: false))
        #expect(t.listPaths(exists: { $0 == "/c/gnome-xdg-terminals.list" }) == ["/c/gnome-xdg-terminals.list", "/c/xdg-terminals.list"])
        #expect(t.listPaths(exists: { _ in false }) == ["/c/xdg-terminals.list"])
    }
}

@Suite struct DefaultTerminalRoundTripTests {
    private func scratch() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rsshterm-dt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// gsettings and xdg-mime as scripts that never run (the fake runner answers): only their paths are looked up.
    private func tools(in dir: String) throws -> String {
        let bin = dir + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in ["gsettings", "xdg-mime"] {
            FileManager.default.createFile(atPath: "\(bin)/\(name)", contents: Data("#!/bin/false\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        return bin
    }

    @Test func makeDefaultAndUndo() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let config = dir + "/config"
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        try "org.gnome.Ptyxis.desktop\n".write(toFile: config + "/gnome-xdg-terminals.list", atomically: true, encoding: .utf8)
        let fake = FakeDesktopTools(hasSchema: true, values: ["exec": "'gnome-terminal'", "ssh": "org.gnome.Ptyxis.desktop"])
        let env = ["XDG_CONFIG_HOME": config, "XDG_CURRENT_DESKTOP": "GNOME", "PATH": try tools(in: dir)]
        let t = LinuxDefaultTerminal(environment: env, home: dir, runner: fake)
        #expect(!t.isDefault())
        #expect(!t.canUndo)

        try await t.makeDefault(executable: "/usr/bin/rsshterm")
        #expect(t.isDefault())
        #expect(t.canUndo)
        #expect(try String(contentsOfFile: config + "/xdg-terminals.list", encoding: .utf8) == "dev.rsshterm.RSSHTerm.desktop\n")
        #expect(LinuxDefaultTerminal.isPreferred(in: try String(contentsOfFile: config + "/gnome-xdg-terminals.list", encoding: .utf8)))
        #expect(fake.value("exec") == "/usr/bin/rsshterm")
        #expect(fake.value("exec-arg") == "-e")
        #expect(fake.value("ssh") == LinuxDefaultTerminal.desktopID)

        try await t.undo()
        #expect(!t.isDefault())
        #expect(!t.canUndo)
        #expect(!FileManager.default.fileExists(atPath: config + "/xdg-terminals.list"))
        #expect(try String(contentsOfFile: config + "/gnome-xdg-terminals.list", encoding: .utf8) == "org.gnome.Ptyxis.desktop\n")
        #expect(fake.value("exec") == "'gnome-terminal'")
        #expect(fake.value("ssh") == "org.gnome.Ptyxis.desktop")
    }

    @Test func noGnomeSchemaNoGsettingsChange() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = FakeDesktopTools(hasSchema: false)
        let t = LinuxDefaultTerminal(environment: ["XDG_CONFIG_HOME": dir + "/c", "PATH": try tools(in: dir)], home: dir, runner: fake)
        try await t.makeDefault(executable: "/usr/bin/rsshterm")
        #expect(!fake.calls.contains { $0.dropFirst().first == "set" })
        #expect(t.isDefault())
    }
}
