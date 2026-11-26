import Foundation

/// The commands an upload needs on the server: run a command over its own channel, and the home directory.
public protocol RemoteShell: Sendable {
    /// Runs `command` on a new exec channel of the session's connection and returns its standard output.
    func run(_ command: String) async throws -> String
    /// The login directory (SFTP realpath of ".").
    func homeDirectory() async throws -> String
}

/// Where an upload goes, and how that folder was found (the upload sheet says which).
public struct UploadDirectory: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The shell reported it with OSC 7.
        case reported
        /// Read from the shell's process on the server.
        case probed
        /// Nothing better known: the home directory.
        case home
    }

    public var path: String
    public var source: Source

    public init(path: String, source: Source) {
        self.path = path
        self.source = source
    }
}

/// Picks the upload folder: the shell's current directory, never `$HOME` while that can be found.
/// 1. what the shell reported with OSC 7; 2. the cwd of the shell behind our PTY, read on a second channel
/// (`ShellProbe`); 3. the home directory.
public enum UploadDirectoryResolver {
    public static func resolve(reported: String?, marker: String, shell: any RemoteShell) async -> UploadDirectory? {
        if let path = RemotePath.directory(fromOSC7: reported) { return UploadDirectory(path: path, source: .reported) }
        if let script = ShellProbe.script(marker: marker), let output = try? await shell.run(script),
           let path = ShellProbe.directory(fromOutput: output), RemotePath.isUsableDirectory(path) {
            return UploadDirectory(path: path, source: .probed)
        }
        if let home = try? await shell.homeDirectory(), RemotePath.isUsableDirectory(home) { return UploadDirectory(path: home, source: .home) }
        return nil
    }
}
