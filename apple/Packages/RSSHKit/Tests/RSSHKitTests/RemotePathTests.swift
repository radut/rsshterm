import Foundation
import Testing
@testable import RSSHKit

@Suite struct RemotePathTests {
    @Test func plainPathsStayUnquoted() {
        #expect(RemotePath.shellQuoted("/home/me/photo-1.jpg") == "/home/me/photo-1.jpg")
    }

    @Test func otherPathsAreSingleQuoted() {
        #expect(RemotePath.shellQuoted("/tmp/My Photo.jpg") == "'/tmp/My Photo.jpg'")
        #expect(RemotePath.shellQuoted("/tmp/it's.txt") == #"'/tmp/it'\''s.txt'"#)
        #expect(RemotePath.shellQuoted("/tmp/$(rm -rf ~)") == "'/tmp/$(rm -rf ~)'")
        #expect(RemotePath.shellQuoted("/tmp/a`b`;c") == "'/tmp/a`b`;c'")
        #expect(RemotePath.shellQuoted("") == "''")
    }

    @Test func tildeStaysExpandable() {
        #expect(RemotePath.shellQuoted("~/My Files/a.txt") == "~/'My Files/a.txt'")
    }

    @Test func joinAddsOneSlash() {
        #expect(RemotePath.join("/home/me", "a.txt") == "/home/me/a.txt")
        #expect(RemotePath.join("/", "a.txt") == "/a.txt")
        #expect(RemotePath.join("/srv/", "a.txt") == "/srv/a.txt")
    }

    @Test func fileNamesAreOneComponent() {
        #expect(RemotePath.safeFileName("../../etc/passwd") == ".._.._etc_passwd")
        #expect(RemotePath.safeFileName("  ") == "upload")
        #expect(RemotePath.safeFileName("..") == "upload")
        #expect(RemotePath.safeFileName("a\u{0}b\nc") == "a_b_c")
        #expect(RemotePath.safeFileName("IMG 1.HEIC") == "IMG 1.HEIC")
        #expect(RemotePath.safeFileName("a⏎b⌃C.txt") == "a_b_C.txt")
    }

    @Test func osc7Reports() {
        #expect(RemotePath.directory(fromOSC7: "file://box/home/me/My%20Dir") == "/home/me/My Dir")
        #expect(RemotePath.directory(fromOSC7: "file:///srv/data") == "/srv/data")
        #expect(RemotePath.directory(fromOSC7: "file://box/tmp/100%") == "/tmp/100%")
        #expect(RemotePath.directory(fromOSC7: "/var/log") == "/var/log")
        #expect(RemotePath.directory(fromOSC7: "http://x/y") == nil)
        #expect(RemotePath.directory(fromOSC7: nil) == nil)
        #expect(RemotePath.directory(fromOSC7: "file://hostonly") == nil)
        #expect(RemotePath.directory(fromOSC7: "file://h/tmp/a%0Ab") == nil)
        #expect(RemotePath.directory(fromOSC7: "file://h/tmp/x⏎y") == nil)
        #expect(RemotePath.directory(fromOSC7: "/tmp/\u{9B}x") == nil)
    }
}

/// Answers the probe and the home lookup from canned values, and records what ran.
final class FakeRemoteShell: RemoteShell, @unchecked Sendable {
    var probeOutput: String?
    var home: String?
    private(set) var commands: [String] = []

    init(probeOutput: String? = nil, home: String? = "/home/me") {
        self.probeOutput = probeOutput
        self.home = home
    }

    func run(_ command: String) async throws -> String {
        commands.append(command)
        guard let probeOutput else { throw CocoaError(.fileReadUnknown) }
        return probeOutput
    }

    func homeDirectory() async throws -> String {
        guard let home else { throw CocoaError(.fileReadUnknown) }
        return home
    }
}

@Suite struct UploadDirectoryResolverTests {
    let marker = "6F1C2A4B-0000-4000-8000-00000000ABCD"

    @Test func theReportedFolderWinsAndNothingRuns() async {
        let shell = FakeRemoteShell(probeOutput: "cwd:/elsewhere\n")
        let dir = await UploadDirectoryResolver.resolve(reported: "file://box/srv/www", marker: marker, shell: shell)
        #expect(dir == UploadDirectory(path: "/srv/www", source: .reported))
        #expect(shell.commands.isEmpty)
    }

    @Test func withoutAReportTheShellIsProbed() async {
        let shell = FakeRemoteShell(probeOutput: "noise\ncwd:/var/log\n")
        let dir = await UploadDirectoryResolver.resolve(reported: nil, marker: marker, shell: shell)
        #expect(dir == UploadDirectory(path: "/var/log", source: .probed))
        #expect(shell.commands.count == 1)
        #expect(shell.commands[0].contains(marker))
    }

    @Test func homeOnlyWhenTheProbeFindsNothing() async {
        let empty = FakeRemoteShell(probeOutput: "")
        #expect(await UploadDirectoryResolver.resolve(reported: nil, marker: marker, shell: empty)
            == UploadDirectory(path: "/home/me", source: .home))
        let failing = FakeRemoteShell(probeOutput: nil)
        #expect(await UploadDirectoryResolver.resolve(reported: "garbage", marker: marker, shell: failing)
            == UploadDirectory(path: "/home/me", source: .home))
    }

    @Test func nothingWhenEvenHomeIsUnknown() async {
        let shell = FakeRemoteShell(probeOutput: nil, home: nil)
        #expect(await UploadDirectoryResolver.resolve(reported: nil, marker: marker, shell: shell) == nil)
    }

    @Test func aMarkerThatIsNotAnIdIsNeverPasted() async {
        #expect(ShellProbe.script(marker: "x'; rm -rf ~; '") == nil)
        #expect(ShellProbe.script(marker: "") == nil)
        let shell = FakeRemoteShell(probeOutput: "cwd:/x")
        #expect(await UploadDirectoryResolver.resolve(reported: nil, marker: "a b", shell: shell)?.source == .home)
        #expect(shell.commands.isEmpty)
    }

    @Test func aProbedPathWithTokensFallsBackToHome() async {
        let shell = FakeRemoteShell(probeOutput: "cwd:/tmp/x⇥y")
        #expect(await UploadDirectoryResolver.resolve(reported: nil, marker: marker, shell: shell)?.source == .home)
    }

    @Test func probeOutputParsing() {
        #expect(ShellProbe.directory(fromOutput: "cwd:/a b/c\n") == "/a b/c")
        #expect(ShellProbe.directory(fromOutput: "cwd:relative\n") == nil)
        #expect(ShellProbe.directory(fromOutput: "") == nil)
    }

    #if os(Linux)
    /// The real script against a real process tree: a child holding the marker, in /tmp.
    @Test func probeFindsTheMarkedProcessCwd() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "cd /tmp && sleep 20"]
        child.environment = ["LC_RSSH_SESSION": marker, "PATH": "/usr/bin:/bin"]
        try child.run()
        defer { child.terminate() }
        Thread.sleep(forTimeInterval: 0.3)
        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh")
        probe.arguments = ["-c", try #require(ShellProbe.script(marker: marker))]
        probe.standardOutput = pipe
        try probe.run()
        probe.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(ShellProbe.directory(fromOutput: output) == "/tmp")
    }
    #endif
}

@Suite struct ShellIntegrationTests {
    @Test func installIsIdempotentAndTagged() {
        let cmd = ShellIntegration.installCommand
        #expect(cmd.contains("grep -qF"))
        #expect(cmd.contains("~/.bashrc"))
        #expect(cmd.contains("~/.zshrc"))
        #expect(cmd.hasSuffix("exit 0"))
        #expect(ShellIntegration.bashHook.contains("]7;file://"))
        #expect(ShellIntegration.zshHook.contains("add-zsh-hook precmd"))
    }

    #if os(Linux)
    /// Runs the install twice in a scratch HOME: one line per rc file, and the bash hook really prints OSC 7.
    @Test func installRunsTwiceWithoutDuplicating() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for _ in 0..<2 { _ = try sh(ShellIntegration.installCommand, home: home) }
        let rc = try String(contentsOf: home.appendingPathComponent(".bashrc"), encoding: .utf8)
        #expect(rc.components(separatedBy: ShellIntegration.tag).count == 2)
        let out = try sh(". ~/.bashrc; cd /tmp; eval \"$PROMPT_COMMAND\"", home: home, shell: "/bin/bash")
        #expect(out.contains("\u{1B}]7;file://"))
        #expect(out.hasSuffix("/tmp\u{1B}\\"))
    }

    private func sh(_ script: String, home: URL, shell: String = "/bin/sh") throws -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", script]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/bash"]
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    #endif
}
