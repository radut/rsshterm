import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `SecretStore` as one file per account in an owner-only directory (0700, files 0600). Not encrypted: the fallback
/// when no Secret Service answers (a server without a desktop session, a minimal window manager), chosen by
/// `DesktopSecretStore`, which tells the user so.
public struct FileSecretStore: SecretStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `$XDG_DATA_HOME/rssh/secrets`, or `~/.local/share/rssh/secrets` when it is unset or not absolute (XDG spec).
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base: String
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            base = xdg
        } else {
            base = (environment["HOME"] ?? NSHomeDirectory()) + "/.local/share"
        }
        return URL(fileURLWithPath: base).appendingPathComponent("rssh").appendingPathComponent("secrets")
    }

    public func read(account: String) async throws -> Data? {
        let file = try path(account)
        var info = stat()
        guard stat(file, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw SecretStoreError.unavailable(Self.errnoText(file))
        }
        guard info.st_mode & 0o077 == 0 else { throw SecretStoreError.insecurePermissions(file) }
        guard let data = FileManager.default.contents(atPath: file) else {
            throw SecretStoreError.unavailable(Self.errnoText(file))
        }
        return data
    }

    public func write(_ data: Data, account: String) async throws {
        let file = try path(account)
        try ensureDirectory()
        // A new file created 0600 from the start (no window with wider permissions), then renamed over the old one.
        let temp = directory.appendingPathComponent(".\(account).\(UUID().uuidString)").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecretStoreError.unavailable(Self.errnoText(temp)) }
        var ok = fchmod(fd, 0o600) == 0
        ok = ok && data.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = Glibc_write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temp, file) == 0 else {
            let message = Self.errnoText(file)
            unlink(temp)
            throw SecretStoreError.unavailable(message)
        }
    }

    public func delete(account: String) async throws {
        let file = try path(account)
        guard unlink(file) == 0 || errno == ENOENT else { throw SecretStoreError.unavailable(Self.errnoText(file)) }
    }

    private func path(_ account: String) throws -> String {
        try SecretAccount.validate(account)
        return directory.appendingPathComponent(account).path
    }

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw SecretStoreError.unavailable("\(directory.path) could not be created.")
        }
        guard chmod(directory.path, 0o700) == 0 else { throw SecretStoreError.unavailable(Self.errnoText(directory.path)) }
    }

    private static func errnoText(_ path: String) -> String { "\(path): \(String(cString: strerror(errno)))" }
}

/// `write(2)`, named apart from `SecretStore.write`.
@inline(__always)
private func Glibc_write(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, buf, count)
}
