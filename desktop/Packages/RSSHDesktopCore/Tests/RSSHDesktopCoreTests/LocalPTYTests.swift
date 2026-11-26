import Foundation
import Testing
@testable import RSSHDesktopCore

/// Reads the PTY's output until `until` holds for the text so far, or the stream ends, or `timeout` passes.
func collect(_ pty: LocalPTY, timeout: Duration = .seconds(10), until: @escaping @Sendable (String) -> Bool = { _ in false })
    async -> String {
    await withTaskGroup(of: String?.self) { group in
        group.addTask {
            var text = ""
            for await chunk in pty.output {
                text += String(decoding: chunk, as: UTF8.self)
                if until(text) { break }
            }
            return text
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next()!
        group.cancelAll()
        return first ?? "<timeout>"
    }
}

@Suite(.serialized) struct LocalPTYTests {
    private func config(_ argv: [String], env: [String: String] = ["PATH": "/usr/bin:/bin"],
                        directory: String? = nil, rows: UInt16 = 24, cols: UInt16 = 80) throws -> PTYConfiguration {
        try PTYConfiguration(command: argv, environment: env, directory: directory, size: TerminalSize(rows: rows, columns: cols))
    }

    @Test func echoHi() async throws {
        let pty = try LocalPTY.spawn(config(["echo", "hi"]))
        let text = await collect(pty)
        #expect(text.contains("hi"))
        #expect(await pty.waitForExit() == .exited(0))
    }

    @Test func exitCodeAndSignal() async throws {
        let failing = try LocalPTY.spawn(config(["sh", "-c", "exit 3"]))
        #expect(await failing.waitForExit() == .exited(3))

        let sleeper = try LocalPTY.spawn(config(["sleep", "30"]))
        sleeper.terminate()
        #expect(await sleeper.waitForExit() == .signaled(SIGHUP))
    }

    @Test func writeGoesToTheChild() async throws {
        let pty = try LocalPTY.spawn(config(["cat"]))
        try pty.write(Data("ping\n".utf8))
        let text = await collect(pty) { $0.components(separatedBy: "ping").count >= 3 } // the echo, then cat's copy
        #expect(text.components(separatedBy: "ping").count >= 3)
        try pty.write(Data([4])) // Ctrl+D
        #expect(await pty.waitForExit() == .exited(0))
    }

    @Test func initialSizeAndResize() async throws {
        let first = try LocalPTY.spawn(config(["stty", "size"], rows: 33, cols: 101))
        #expect(await collect(first).contains("33 101"))

        let pty = try LocalPTY.spawn(config(["sh", "-c", "read line; stty size"]))
        try pty.resize(TerminalSize(rows: 40, columns: 120))
        try pty.write(Data("go\n".utf8))
        #expect(await collect(pty) { $0.contains("40 120") }.contains("40 120"))
    }

    @Test func workingDirectory() async throws {
        let pty = try LocalPTY.spawn(config(["pwd"], directory: "/tmp"))
        #expect(await collect(pty).contains("/tmp"))
    }

    @Test func environmentReachesTheChild() async throws {
        let env = ShellEnvironment.make(base: ["PATH": "/usr/bin:/bin", "HOME": "/root"], agentSocket: "/run/test/agent.sock",
                                        appVersion: "1.2.3")
        let pty = try LocalPTY.spawn(config(["sh", "-c", "echo \"[$TERM|$COLORTERM|$TERM_PROGRAM|$TERM_PROGRAM_VERSION|$SSH_AUTH_SOCK]\""], env: env))
        #expect(await collect(pty).contains("[xterm-256color|truecolor|rSshTerm|1.2.3|/run/test/agent.sock]"))
    }

    @Test func closeEndsOutputAndRefusesWrites() async throws {
        // "ready" first: closing right after spawn could race the child's setup of its controlling terminal (seen
        // once on a CI runner). `exec` leaves sleep as the process on the terminal.
        let pty = try LocalPTY.spawn(config(["sh", "-c", "echo ready; exec sleep 30"]))
        #expect(await collect(pty, until: { $0.contains("ready") }).contains("ready"))
        pty.close()
        #expect(throws: PTYError.closed) { try pty.write(Data("x".utf8)) }
        #expect(throws: PTYError.closed) { try pty.resize(TerminalSize(rows: 2, columns: 2)) }
        #expect(await collect(pty) != "<timeout>") // the stream finished
        // Master closed: the hangup ends the child, as the kernel's SIGHUP or, where a shell reports it, 128 + SIGHUP.
        let status = await exitStatus(pty, within: .seconds(10))
        #expect(status == .signaled(SIGHUP) || status == .exited(128 + SIGHUP), "\(String(describing: status))")
    }

    /// The exit status, or nil (and the child killed) when it does not exit in time, so a missing hangup fails
    /// the test instead of hanging the suite.
    private func exitStatus(_ pty: LocalPTY, within limit: Duration) async -> RSSHDesktopCore.ExitStatus? {
        await withTaskGroup(of: RSSHDesktopCore.ExitStatus?.self) { group in
            group.addTask { await pty.waitForExit() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil { pty.terminate(signal: SIGKILL) }
            group.cancelAll()
            return first
        }
    }

    @Test func missingCommandThrows() {
        #expect(throws: PTYError.executableNotFound("no-such-command-rssh")) {
            try PTYConfiguration(command: ["no-such-command-rssh"], environment: ["PATH": "/usr/bin:/bin"])
        }
        #expect(throws: PTYError.emptyCommand) { try PTYConfiguration(command: [], environment: [:]) }
    }

    @Test func inheritedDescriptorsAreClosedInTheChild() async throws {
        let pipe = Pipe() // an fd without close-on-exec in this process
        defer { try? pipe.fileHandleForWriting.close() }
        let fd = pipe.fileHandleForWriting.fileDescriptor
        let pty = try LocalPTY.spawn(config(["sh", "-c", "if [ -e /proc/self/fd/\(fd) ] || ( : >&\(fd) ) 2>/dev/null; then echo OPEN; else echo CLOSED; fi"]))
        let text = await collect(pty)
        #expect(text.contains("CLOSED"), "\(text)")
    }
}

@Suite struct ShellEnvironmentTests {
    @Test func injectsTerminalAndAgent() {
        let env = ShellEnvironment.make(base: ["PATH": "/bin", "SSH_AUTH_SOCK": "/old.sock", "TERM": "dumb"],
                                        agentSocket: "/new.sock", appVersion: "0.1.0")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "rSshTerm")
        #expect(env["TERM_PROGRAM_VERSION"] == "0.1.0")
        #expect(env["SSH_AUTH_SOCK"] == "/new.sock")
        #expect(env["PATH"] == "/bin")
        #expect(env["LANG"] == "en_US.UTF-8")
    }

    @Test func keepsTheUsersAgentWhenOursIsOffAndTheirLocale() {
        let env = ShellEnvironment.make(base: ["SSH_AUTH_SOCK": "/old.sock", "LC_ALL": "de_DE.UTF-8"], agentSocket: nil,
                                        appVersion: "0.1.0")
        #expect(env["SSH_AUTH_SOCK"] == "/old.sock")
        #expect(env["LANG"] == nil)
    }

    @Test func userShell() {
        #expect(ShellEnvironment.userShell(environment: ["SHELL": "/bin/sh"]) == "/bin/sh")
        #expect(ShellEnvironment.userShell(environment: ["SHELL": "relative/zsh"]) != "relative/zsh")
        #expect(ShellEnvironment.userShell(environment: [:]).hasPrefix("/"))
    }

    @Test func loginShellArgv() throws {
        let config = try PTYConfiguration.shell(environment: ["SHELL": "/bin/sh", "PATH": "/bin"], agentSocket: nil,
                                                appVersion: "1")
        #expect(config.executable == "/bin/sh")
        #expect(config.arguments == ["-sh"])
    }

    @Test func resolveFindsCommandsOnPath() {
        #expect(ShellEnvironment.resolve("sh", path: "/nonexistent:/bin") == "/bin/sh")
        #expect(ShellEnvironment.resolve("/bin/sh", path: nil) == "/bin/sh")
        #expect(ShellEnvironment.resolve("nope-rssh", path: "/bin") == nil)
    }
}
