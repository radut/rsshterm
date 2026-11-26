import Foundation
import RSSHKit

/// The working folder a shell reports with OSC 7 (`ESC ] 7 ; file://host/path BEL`, or ST `ESC \` at the end),
/// which `ShellIntegration` installs on servers and most local shells send. The terminal view hands the payload
/// here; "Open File Manager Here" opens the commander at it (remote tab: that server over SFTP; local tab: this
/// computer).
public struct ShellDirectory: Equatable, Sendable {
    /// The host part ("" or "localhost" for local shells).
    public let host: String
    public let path: FilePath

    public init(host: String, path: FilePath) {
        self.host = host
        self.path = path
    }

    /// Parses the OSC 7 payload ("7;file://host/path") or a whole sequence; nil when it is not a file URL.
    public static func parse(osc7 text: String) -> ShellDirectory? {
        var payload = Substring(text)
        if payload.hasPrefix("\u{1b}]") { payload = payload.dropFirst(2) }
        if payload.hasSuffix("\u{07}") { payload = payload.dropLast() }
        if payload.hasSuffix("\u{1b}\\") { payload = payload.dropLast(2) }
        if payload.hasPrefix("7;") { payload = payload.dropFirst(2) }
        guard payload.lowercased().hasPrefix("file://") else { return nil }
        let rest = payload.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash])
        guard let path = String(rest[slash...]).removingPercentEncoding, !path.contains("\0") else { return nil }
        return ShellDirectory(host: host, path: FilePath(path))
    }

    /// True when the host part names this machine (empty, localhost, or `localHostName`).
    public func isLocal(localHostName: String = ProcessInfo.processInfo.hostName) -> Bool {
        let h = host.lowercased()
        let me = localHostName.lowercased()
        return h.isEmpty || h == "localhost" || h == me || h == me.split(separator: ".").first.map(String.init)
    }
}

/// Dragging items out of a pane to Finder / the Linux file manager: local files go as they are; remote ones are
/// downloaded into a private folder first and those copies are dragged (the OS needs file URLs).
public enum FileDragOut {
    public static func urls(for items: [FileItem], from source: any FileSource, isLocal: Bool,
                            stagingIn directory: URL = RemoteEditSession.defaultDirectory()
                                .appendingPathComponent("drag", isDirectory: true)) async throws -> [URL] {
        if isLocal { return items.map { LocalDisk.url(for: $0.path) } }
        let fm = FileManager.default
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = LocalFileSource(rootURL: folder, displayName: "Drag")
        let engine = TransferEngine()
        let id = await engine.enqueue(TransferRequest(source: source, items: items.map(\.path), destination: staging,
                                                      destinationDirectory: .root, operation: .copy, policy: .overwrite))
        let result = await engine.waitUntilFinished(id)
        if case .failed(let message)? = result?.state { throw FileSourceError.failed(message) }
        return items.map { folder.appendingPathComponent($0.name) }
    }
}
