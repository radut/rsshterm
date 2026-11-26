import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum UnixSocketError: Error, Equatable, Sendable {
    case pathTooLong(String)
    /// The socket's directory exists but is not ours, or is a symlink: refuse rather than serve keys from it.
    case unsafeDirectory(String)
    /// Something that is not a socket sits at the socket path.
    case pathOccupied(String)
    case system(String, Int32)
}

/// Thin POSIX wrappers for AF_UNIX stream sockets, the same on Linux and macOS.
enum UnixSocket {
    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    static func address(_ path: String) throws(UnixSocketError) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw .pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    static func makeSocket() throws(UnixSocketError) -> Int32 {
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw .system("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    /// A listening socket at `path` (mode 0600). A stale socket there is replaced; anything else is an error.
    static func listen(at path: String, backlog: Int32 = 16) throws(UnixSocketError) -> Int32 {
        var addr = try address(path)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw .pathOccupied(path) }
            unlink(path)
        }
        let fd = try makeSocket()
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw .system("bind", code)
        }
        guard chmod(path, 0o600) == 0, Glibc_listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw .system("listen", code)
        }
        return fd
    }

    static func connect(to path: String) throws(UnixSocketError) -> Int32 {
        var addr = try address(path)
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw .system("connect", code)
        }
        return fd
    }

    /// Creates `path` as a 0700 directory, or checks an existing one: a real directory (not a symlink) owned by
    /// this user, then tightened to 0700.
    static func ensurePrivateDirectory(_ path: String) throws(UnixSocketError) {
        var info = stat()
        if lstat(path, &info) != 0 {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != path, lstat(parent, &info) != 0 {
                do {
                    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                } catch { throw .system("mkdir", EACCES) }
            }
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw .system("mkdir", errno) }
            guard lstat(path, &info) == 0 else { throw .system("lstat", errno) }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw .unsafeDirectory(path) }
        guard chmod(path, 0o700) == 0 else { throw .system("chmod", errno) }
    }

    /// Waits until `fd` is readable or `milliseconds` pass. True when readable (or hung up).
    static func waitReadable(_ fd: Int32, milliseconds: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, milliseconds) > 0
    }

    /// Writes all of `data`; false when the peer went away.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                #if canImport(Darwin)
                Darwin.write(fd, raw.baseAddress! + offset, data.count - offset)
                #else
                Glibc.send(fd, raw.baseAddress! + offset, data.count - offset, Int32(MSG_NOSIGNAL))
                #endif
            }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return false
            }
            offset += written
        }
        return true
    }
}

private func Glibc_listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.listen(fd, backlog)
    #else
    Glibc.listen(fd, backlog)
    #endif
}

private func Glibc_connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.connect(fd, addr, len)
    #else
    Glibc.connect(fd, addr, len)
    #endif
}
