import Foundation
import RSSHKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The process in front of a terminal: the leader of the tty's foreground process group (its pid is the group
/// id), with its argv and working directory. Linux reads /proc; macOS sysctl KERN_PROCARGS2 and proc_pidinfo.
/// This is what names a local tab: `vim notes.md`, or `ssh root@sv1` (whose target becomes user@host).
public struct ForegroundProcess: Equatable, Sendable {
    public let pid: pid_t
    public let argv: [String]
    public let cwd: String?

    public init(pid: pid_t, argv: [String], cwd: String?) {
        self.pid = pid
        self.argv = argv
        self.cwd = cwd
    }

    /// The foreground process group of the terminal whose master is `fd` (VTE: `vte_pty_get_fd`); nil when the
    /// fd is closed or no group is in front.
    public static func group(masterFD fd: Int32) -> pid_t? {
        let group = tcgetpgrp(fd)
        return group > 0 ? group : nil
    }

    /// The foreground process of the terminal whose master is `fd`.
    public static func current(masterFD fd: Int32) -> ForegroundProcess? {
        group(masterFD: fd).flatMap { read(pid: $0) }
    }

    /// A process's argv and folder; nil when it is gone (or not ours to read on macOS).
    public static func read(pid: pid_t) -> ForegroundProcess? {
        guard let argv = arguments(of: pid), !argv.isEmpty else { return nil }
        return ForegroundProcess(pid: pid, argv: argv, cwd: workingDirectory(of: pid))
    }

    /// The facts of a local tab whose own program (the shell) is `shellPID`: the job in front when it is another
    /// process group, else none, with the folder of whichever is in front.
    public static func localFacts(masterFD fd: Int32, shellPID: pid_t, user: String?, host: String?,
                                  home: String? = nil) -> LocalProcessFacts? {
        guard let group = group(masterFD: fd) else { return nil }
        let front = read(pid: group)
        let isJob = group != shellPID && front != nil
        let cwd = (isJob ? front?.cwd : nil) ?? workingDirectory(of: shellPID)
        return LocalProcessFacts(foreground: isJob ? front?.argv : nil, cwd: cwd, user: user, host: host, home: home)
    }

    #if canImport(Darwin)
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs2(Data(buffer[0..<size]))
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return end == 0 ? nil : String(decoding: bytes[0..<end], as: UTF8.self)
        }
    }
    #else
    static func arguments(of pid: pid_t) -> [String]? {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline") else { return nil }
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd")
    }
    #endif

    /// KERN_PROCARGS2: a 4-byte argc, the executable path, NUL padding, then argc NUL-terminated arguments (the
    /// environment follows). Parsed on every OS so it is tested on Linux.
    static func parseProcArgs2(_ data: Data) -> [String]? {
        guard data.count >= 4 else { return nil }
        let argc = data.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return nil }
        var index = data.startIndex + 4
        while index < data.endIndex, data[index] != 0 { index += 1 } // exec path
        while index < data.endIndex, data[index] == 0 { index += 1 } // padding
        var argv: [String] = []
        while argv.count < argc, index < data.endIndex {
            let end = data[index...].firstIndex(of: 0) ?? data.endIndex
            argv.append(String(decoding: data[index..<end], as: UTF8.self))
            index = end < data.endIndex ? end + 1 : end
        }
        return argv.isEmpty ? nil : argv
    }
}

extension LocalPTY {
    /// The process in front of this terminal (this PTY's own child when nothing else runs); nil once closed.
    public func foregroundProcess() -> ForegroundProcess? {
        withMasterFD { ForegroundProcess.current(masterFD: $0) } ?? nil
    }

    /// The facts for this tab's title: the job in front of the shell (nil at the prompt) and the folder.
    public func localFacts(user: String?, host: String?, home: String? = nil) -> LocalProcessFacts? {
        withMasterFD { fd in
            ForegroundProcess.localFacts(masterFD: fd, shellPID: pid, user: user, host: host, home: home)
        } ?? nil
    }
}
