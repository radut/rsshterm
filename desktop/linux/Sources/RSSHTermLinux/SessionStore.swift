import Foundation
import RSSHDesktopCore

/// What session restore saves: the core `Session` (windows → tabs → splits, manual tab titles, focus), with each
/// local shell's working directory as its shell last reported it (OSC 7), so a restored tab opens there.
public enum SessionSnapshot {
    public static func capture(windows: [Window], directories: [PaneID: String]) -> Session {
        Session(windows: windows.map { window in
            Window(id: window.id, tabs: window.tabs.map { tab in
                tab.replacingContents { pane in
                    guard case .localShell(let command, let directory) = pane.content else { return pane.content }
                    return .localShell(command: command, directory: directories[pane.id] ?? directory)
                }
            }, selectedIndex: window.selectedIndex, broadcastsInput: window.broadcastsInput)
        })
    }
}

/// `$XDG_STATE_HOME/rssh/session.json` (0600). A missing, damaged, empty or newer file restores nothing.
public enum SessionStore {
    public static func defaultURL(environment: [String: String], home: String = NSHomeDirectory()) -> URL {
        let base = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "\(home)/.local/state"
        return URL(fileURLWithPath: "\(base)/rssh/session.json")
    }

    public static func load(from url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              session.version <= Session.currentVersion, !session.windows.isEmpty else { return nil }
        return session
    }

    public static func save(_ session: Session, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
