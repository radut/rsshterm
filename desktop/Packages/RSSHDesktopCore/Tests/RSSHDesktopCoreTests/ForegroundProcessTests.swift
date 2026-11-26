import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@Suite(.serialized) struct ForegroundProcessTests {
    private func spawn(_ argv: [String], directory: String? = nil) throws -> LocalPTY {
        try LocalPTY.spawn(PTYConfiguration(command: argv, environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp",
                                                                          "PS1": "$ ", "TERM": "dumb"],
                                            directory: directory))
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Polls `read` until `ok` holds (programs start a moment after the shell reads the line).
    private func eventually<T>(_ read: () -> T?, _ ok: (T) -> Bool) async -> T? {
        for _ in 0..<100 {
            if let value = read(), ok(value) { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return read()
    }

    @Test func procArgs2Layout() {
        // macOS KERN_PROCARGS2: argc, the exec path, NUL padding, argv, then the environment.
        var data = Data()
        var argc: Int32 = 2
        data.append(Data(bytes: &argc, count: 4))
        data.append(Data("/usr/bin/vim\0\0\0vim\0/etc/hosts\0PATH=/bin\0".utf8))
        #expect(ForegroundProcess.parseProcArgs2(data) == ["vim", "/etc/hosts"])
        #expect(ForegroundProcess.parseProcArgs2(Data([1, 0])) == nil)
    }

    @Test func childAloneIsTheForegroundAndItsOwnShell() async throws {
        let dir = FileManager.default.temporaryDirectory.path
        let pty = try spawn(["sleep", "30"], directory: dir)
        defer { pty.terminate(signal: SIGKILL) }
        let process = await eventually({ pty.foregroundProcess() }) { $0.argv == ["sleep", "30"] }
        #expect(process?.pid == pty.pid)
        #expect(process?.argv == ["sleep", "30"])
        #expect(process.map { Self.resolved($0.cwd ?? "") } == Self.resolved(dir))
        // The tab's own program in front: nothing runs "in" it.
        #expect(pty.localFacts(user: "me", host: "box")?.foreground == nil)
    }

    @Test func jobInAnInteractiveShell() async throws {
        let pty = try spawn(["bash", "--norc", "--noprofile", "-i"], directory: "/")
        defer { pty.terminate(signal: SIGKILL) }
        Task { for await _ in pty.output {} } // keep the PTY drained
        let idle = await eventually({ pty.localFacts(user: "me", host: "box", home: "/tmp") }) { $0.cwd == "/" }
        #expect(idle?.foreground == nil)
        try pty.write(Data("cd /tmp && sleep 31 5\n".utf8))
        let busy = await eventually({ pty.localFacts(user: "me", host: "box", home: "/tmp") }) {
            $0.foreground?.first == "sleep"
        }
        #expect(busy?.foreground == ["sleep", "31", "5"])
        #expect(busy?.cwd.map(Self.resolved) == Self.resolved("/tmp")) // /private/tmp on macOS
        #expect(busy?.user == "me")
        let facts = TabTitleSources(local: busy).facts()
        #expect(TabTitleSettings().label(for: facts).subtitle == "me@box · sleep 31 5")
    }

    @Test func sshInATabNamesTheTarget() {
        let facts = TabTitleSources(local: LocalProcessFacts(foreground: ["ssh", "-l", "root", "sv1"], cwd: "/home/me",
                                                             user: "me", host: "box")).facts()
        #expect(TabTitleSettings().label(for: facts).title == "root@sv1")
    }

    @Test func closedPTYHasNoForeground() async throws {
        let pty = try spawn(["true"])
        _ = await pty.waitForExit()
        pty.close()
        try await Task.sleep(for: .milliseconds(400))
        #expect(pty.foregroundProcess() == nil)
    }
}
