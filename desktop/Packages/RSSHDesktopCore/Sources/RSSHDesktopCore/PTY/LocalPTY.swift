import CRSSHPTY
import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum PTYError: Error, Equatable, Sendable {
    case emptyCommand
    case executableNotFound(String)
    /// The PTY was closed; nothing more can be written.
    case closed
    /// A system call failed: its name and errno.
    case system(String, Int32)
}

/// Rows and columns of a terminal.
public struct TerminalSize: Equatable, Sendable {
    public let rows: UInt16
    public let columns: UInt16

    public init(rows: UInt16, columns: UInt16) {
        self.rows = max(rows, 1)
        self.columns = max(columns, 1)
    }
}

/// What to start on a new PTY: a resolved executable, its argv (argv[0] included), the environment, the directory.
public struct PTYConfiguration: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String?
    public let size: TerminalSize

    /// `command` is argv; argv[0] is looked up on the environment's PATH.
    public init(command: [String], environment: [String: String], directory: String? = nil,
                size: TerminalSize = TerminalSize(rows: 24, columns: 80)) throws(PTYError) {
        guard let name = command.first, !name.isEmpty else { throw .emptyCommand }
        guard let path = ShellEnvironment.resolve(name, path: environment["PATH"]) else { throw .executableNotFound(name) }
        self.init(executable: path, arguments: command, environment: environment, directory: directory, size: size)
    }

    public init(executable: String, arguments: [String], environment: [String: String], directory: String?,
                size: TerminalSize) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.size = size
    }

    /// The user's login shell (argv[0] "-zsh", as Terminal.app and iTerm2 start it) with the tab environment.
    public static func shell(environment: [String: String], agentSocket: String?, appVersion: String,
                             directory: String? = nil, size: TerminalSize = TerminalSize(rows: 24, columns: 80))
        throws(PTYError) -> PTYConfiguration {
        let shell = ShellEnvironment.userShell(environment: environment)
        let name = shell.split(separator: "/").last.map(String.init) ?? "sh"
        return PTYConfiguration(executable: shell, arguments: ["-" + name],
                                environment: ShellEnvironment.make(base: environment, agentSocket: agentSocket,
                                                                   appVersion: appVersion),
                                directory: directory ?? environment["HOME"], size: size)
    }
}

/// How the child ended.
public enum ExitStatus: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    /// From a waitpid status (the layout is the same on Linux and macOS).
    init(waitStatus status: Int32) {
        let signal = status & 0x7f
        self = signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    }
}

/// The master fd, shared by the reader thread and the PTY. Only the reader closes it (when output ends or after
/// `close()`), and writes and resizes run under the same lock and refuse once it is closing, so no call ever uses
/// a closed (or reused) descriptor.
private final class MasterChannel: Sendable {
    private struct State {
        var fd: Int32
        var closing = false
    }
    private let state: Mutex<State>
    let readFD: Int32

    init(fd: Int32) {
        state = Mutex(State(fd: fd))
        readFD = fd
    }

    var isClosing: Bool { state.withLock { $0.closing } }

    func requestClose() { state.withLock { $0.closing = true } }

    /// Called by the reader thread only, after its last read.
    func closeFromReader() {
        state.withLock { s in
            guard s.fd >= 0 else { return }
            _ = Glibc_close(s.fd)
            s.fd = -1
            s.closing = true
        }
    }

    func withOpenFD<R>(_ body: (Int32) throws(PTYError) -> R) throws(PTYError) -> R {
        try state.withLock { (s: inout State) throws(PTYError) -> R in
            guard s.fd >= 0, !s.closing else { throw .closed }
            return try body(s.fd)
        }
    }
}

/// A child process on a pseudo-terminal: output as an async stream, input and resize, exit status. One reader
/// thread and one waiter thread per PTY.
public final class LocalPTY: Sendable {
    public let pid: pid_t
    /// Everything the child writes; finishes when the terminal closes (the child and its children exited) or after
    /// `close()`.
    public let output: AsyncStream<Data>

    private let channel: MasterChannel
    private struct ExitState {
        var status: ExitStatus?
        var waiters: [CheckedContinuation<ExitStatus, Never>] = []
    }
    private let exit = Mutex(ExitState())

    private init(pid: pid_t, channel: MasterChannel, output: AsyncStream<Data>) {
        self.pid = pid
        self.channel = channel
        self.output = output
    }

    public static func spawn(_ config: PTYConfiguration) throws(PTYError) -> LocalPTY {
        let argv = CStringArray(config.arguments)
        let envp = CStringArray(config.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        var masterFD: Int32 = -1
        var childPID: Int32 = -1
        let result = config.executable.withCString { path in
            withOptionalCString(config.directory) { cwd in
                rssh_pty_spawn(path, argv.pointers, envp.pointers, cwd, config.size.rows, config.size.columns,
                               &masterFD, &childPID)
            }
        }
        guard result == 0 else { throw .system("forkpty", errno) }

        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let channel = MasterChannel(fd: masterFD)
        let pty = LocalPTY(pid: childPID, channel: channel, output: stream)
        Thread.detachNewThread { Self.readLoop(channel, into: continuation) }
        Thread.detachNewThread { [weak pty, pid = childPID] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            pty?.finish(ExitStatus(waitStatus: status))
        }
        return pty
    }

    private static func readLoop(_ channel: MasterChannel, into continuation: AsyncStream<Data>.Continuation) {
        let fd = channel.readFD
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !channel.isClosing {
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, 200)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                continuation.yield(Data(buffer[0..<count]))
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                break // 0: EOF; EIO on Linux once the last slave fd closed
            }
        }
        channel.closeFromReader()
        continuation.finish()
    }

    private func finish(_ status: ExitStatus) {
        let waiters = exit.withLock { state in
            state.status = status
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    /// The child's exit status, once it exited.
    public func waitForExit() async -> ExitStatus {
        await withCheckedContinuation { continuation in
            let ready: ExitStatus? = exit.withLock { state in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    public var exitStatus: ExitStatus? { exit.withLock { $0.status } }

    /// Sends bytes as if typed.
    public func write(_ data: Data) throws(PTYError) {
        try channel.withOpenFD { (fd: Int32) throws(PTYError) in
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { Glibc_write(fd, $0.baseAddress! + offset, data.count - offset) }
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw .system("write", errno)
                }
                offset += written
            }
        }
    }

    /// The terminal's new size; the child gets SIGWINCH.
    public func resize(_ size: TerminalSize) throws(PTYError) {
        try channel.withOpenFD { (fd: Int32) throws(PTYError) in
            guard rssh_pty_set_size(fd, size.rows, size.columns) == 0 else { throw .system("ioctl(TIOCSWINSZ)", errno) }
        }
    }

    /// Sends `signal` to the child's process group (SIGHUP, as when a terminal window closes).
    public func terminate(signal: Int32 = SIGHUP) {
        guard exitStatus == nil else { return }
        if kill(-pid, signal) != 0 { kill(pid, signal) }
    }

    /// Runs `body` with the open master fd (under the channel's lock, so it is never a closed or reused fd); nil
    /// once the PTY is closed.
    func withMasterFD<R>(_ body: (Int32) -> R) -> R? {
        try? channel.withOpenFD { (fd: Int32) throws(PTYError) -> R in body(fd) }
    }

    /// Stops reading and closes the master side (within the reader's poll interval); the child sees a hangup.
    /// Writes and resizes fail with `.closed` from now on.
    public func close() { channel.requestClose() }

    deinit { close() }
}

// `write`/`close` are also methods here; these reach the C functions.
private func Glibc_write(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, buffer, count)
    #else
    Glibc.write(fd, buffer, count)
    #endif
}

private func Glibc_close(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}

/// A NULL-terminated `char *[]` that lives as long as this value.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: strings.count + 1)
        for (i, string) in strings.enumerated() { pointers[i] = strdup(string) }
        pointers[strings.count] = nil
    }

    deinit {
        for i in 0..<count { free(pointers[i]) }
        pointers.deallocate()
    }
}
