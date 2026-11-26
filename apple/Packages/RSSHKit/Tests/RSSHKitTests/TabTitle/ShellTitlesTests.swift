import Foundation
import Testing
@testable import RSSHKit

/// The OSC sequences in a byte stream: (number, payload).
func oscSequences(in text: String) -> [(Int, String)] {
    var out: [(Int, String)] = []
    var rest = Substring(text)
    while let start = rest.range(of: "\u{1B}]") {
        rest = rest[start.upperBound...]
        let st = rest.range(of: "\u{1B}\\")
        let bel = rest.firstIndex(of: "\u{07}")
        guard let end = [st?.lowerBound, bel].compactMap({ $0 }).min() else { break }
        let body = rest[..<end]
        if let semi = body.firstIndex(of: ";"), let code = Int(body[..<semi]) {
            out.append((code, String(body[body.index(after: semi)...])))
        }
        rest = rest[end...].dropFirst(st?.lowerBound == end ? 2 : 1)
    }
    return out
}

@Suite struct ShellTitlesTests {
    @Test func snippetsAndInstall() {
        for snippet in [ShellIntegration.bashTitles, ShellIntegration.zshTitles] {
            #expect(snippet.contains("]7;file://"))
            #expect(snippet.contains(" › "))
            #expect(snippet.contains("133;C"))
        }
        #expect(ShellIntegration.fishTitles.contains("fish_title"))
        let cmd = ShellIntegration.installTitlesCommand
        #expect(cmd.contains("~/.bashrc"))
        #expect(cmd.contains("~/.zshrc"))
        #expect(cmd.contains("conf.d/rsshterm.fish"))
        #expect(cmd.contains("grep -qF '\(ShellIntegration.titlesTag)'"))
        #expect(cmd.hasSuffix("exit 0"))
    }

    @Test func scanner() {
        let seqs = oscSequences(in: "a\u{1B}]2;t1\u{07}b\u{1B}]7;file:///x\u{1B}\\c")
        #expect(seqs.map(\.0) == [2, 7])
        #expect(seqs.map(\.1) == ["t1", "file:///x"])
    }

    /// Runs a shell with `snippet` as its rc file, types `lines` and returns its output (prompts included).
    private func run(_ shell: String, args: [String], rcName: String, snippet: String, lines: String) throws -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-titles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rc = dir.appendingPathComponent(rcName)
        try snippet.write(to: rc, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = args.map { $0.replacingOccurrences(of: "RC", with: rc.path) }
        process.currentDirectoryURL = dir
        process.environment = ["HOME": dir.path, "USER": "tester", "PATH": "/usr/bin:/bin", "TERM": "xterm",
                               "ZDOTDIR": dir.path, "HOSTNAME": "box.example.com", "HOST": "box.example.com"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(lines.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `commands`: false for bash before 4.4 (macOS's /bin/bash 3.2 has no PS0): only the prompt reports then.
    private func checkTitles(_ out: String, commands: Bool = true) {
        let seqs = oscSequences(in: out)
        let titles = seqs.filter { $0.0 == 2 }.map(\.1)
        let parsed = titles.compactMap(TerminalTitleParser.parse)
        if commands {
            #expect(parsed.contains(.running(user: "tester", host: "box", commandLine: "echo hi there")), "\(titles)")
            #expect(seqs.contains { $0.0 == 133 && $0.1 == "C" })
        }
        #expect(parsed.contains { if case .prompt(_, "box", "/usr") = $0 { true } else { false } }, "\(titles)")
        let dirs = seqs.filter { $0.0 == 7 }.compactMap { TerminalTitleParser.parseDirectoryURI($0.1) }
        #expect(dirs.contains(DirectoryReport(host: "box.example.com", path: "/usr")), "\(dirs)")
    }

    @Test func bashReportsFolderAndCommand() throws {
        guard let out = try run("/bin/bash", args: ["--rcfile", "RC", "-i"], rcName: "rc.bash",
                                snippet: ShellIntegration.bashTitles,
                                lines: "cd /usr\necho \"v$BASH_VERSINFO.${BASH_VERSINFO[1]}\"\necho hi there\nexit\n")
        else { return }
        let modern = !out.contains("v3.") && !out.contains("v4.0") && !out.contains("v4.1") && !out.contains("v4.2")
            && !out.contains("v4.3")
        checkTitles(out, commands: modern)
    }

    @Test func zshReportsFolderAndCommand() throws {
        let zsh = ["/bin/zsh", "/usr/bin/zsh"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let zsh, let out = try run(zsh, args: ["-i"], rcName: ".zshrc", snippet: ShellIntegration.zshTitles,
                                         lines: "cd /usr\necho hi there\nexit\n")
        else { return }
        checkTitles(out)
    }
}
