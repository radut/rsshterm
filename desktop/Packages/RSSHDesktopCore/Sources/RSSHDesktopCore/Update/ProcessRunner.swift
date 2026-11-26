import Foundation

public struct ProcessOutput: Equatable, Sendable {
    public let status: Int32
    /// stdout and stderr together.
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs helper programs (tar, pkexec, hdiutil, ditto, codesign); injectable so install triggers are testable.
public protocol ProcessRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessOutput
    /// Starts a program that outlives the app (the relaunch helper) without waiting for it.
    func launchDetached(_ executable: String, _ arguments: [String]) throws
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read on a plain thread so a long tar or apt run never holds a cooperative-pool thread.
        let running = RunningProcess(process: process, pipe: pipe)
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let (process, pipe) = (running.process, running.pipe)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ProcessOutput(status: process.terminationStatus,
                                                             output: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    public func launchDetached(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// Hands a started Process to the reader thread; only that thread touches it afterwards.
private struct RunningProcess: @unchecked Sendable {
    let process: Process
    let pipe: Pipe
}
