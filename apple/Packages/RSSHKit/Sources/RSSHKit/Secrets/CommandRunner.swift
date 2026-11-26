import Foundation

/// What a finished command returned.
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    var stderrText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs a helper program (`secret-tool`, `xdg-open`, `open`). Tests script the answers.
public protocol CommandRunner: Sendable {
    /// Runs `command` (looked up on PATH) with `arguments`, writing `stdin` to its input. A command that cannot be
    /// found returns status 127, as a shell would.
    func run(_ command: String, arguments: [String], stdin: Data?) async throws -> CommandResult
}

#if os(Linux) || os(macOS)
/// `CommandRunner` over `Process`, through `/usr/bin/env` so the command is found on PATH. No shell is involved, so
/// arguments are never interpreted.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ command: String, arguments: [String], stdin: Data?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try Self.runBlocking(command, arguments, stdin) })
            }
        }
    }

    private static func runBlocking(_ command: String, _ arguments: [String], _ stdin: Data?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try input.fileHandleForWriting.close()
        // Read both pipes before waiting, so a chatty command cannot block on a full pipe.
        let group = DispatchGroup()
        nonisolated(unsafe) var err = Data()
        group.enter()
        DispatchQueue.global().async {
            err = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: out, stderr: err)
    }
}
#endif
