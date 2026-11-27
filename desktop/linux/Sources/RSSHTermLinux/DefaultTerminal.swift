import Foundation
import RSSHDesktopCore

/// "Make rSshTerm the Default Terminal" on Linux, the user-level part (docs/desktop/terminal-first.md):
/// - xdg-terminal-exec (GNOME 46+, Nautilus "Open in Terminal"): rSshTerm first in ~/.config/xdg-terminals.list and in
///   the desktop-specific lists that exist (gnome-xdg-terminals.list…);
/// - the legacy GNOME key org.gnome.desktop.default-applications.terminal (exec, exec-arg), when the schema exists;
/// - ssh:// links (xdg-mime default … x-scheme-handler/ssh).
/// The system-wide x-terminal-emulator alternative is the .deb's (postinst), never the app's. What was there before
/// is saved, so Undo puts it back.
public struct LinuxDefaultTerminal: Sendable {
    public static let desktopID = "dev.rsshterm.RSSHTerm.desktop"
    public static let gnomeSchema = "org.gnome.desktop.default-applications.terminal"
    public static let sshScheme = "x-scheme-handler/ssh"

    public let configHome: String
    /// XDG_CURRENT_DESKTOP, lowercased, in order ("ubuntu", "gnome").
    public let desktops: [String]
    public let runner: any ProcessRunner
    public let gsettings: String?
    public let xdgMime: String?

    public init(environment: [String: String], home: String, runner: any ProcessRunner) {
        configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "\(home)/.config"
        desktops = (environment["XDG_CURRENT_DESKTOP"] ?? "").split(separator: ":").map { $0.lowercased() }
        self.runner = runner
        gsettings = ShellEnvironment.resolve("gsettings", path: environment["PATH"])
        xdgMime = ShellEnvironment.resolve("xdg-mime", path: environment["PATH"])
    }

    // MARK: The lists (pure)

    /// The entries of an xdg-terminals.list: one desktop file ID per line (an optional `:action`), `#` comments.
    public static func entries(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static func isPreferred(in text: String) -> Bool {
        entries(text).first.map { $0.split(separator: ":").first.map(String.init) == desktopID } ?? false
    }

    /// `text` with rSshTerm first (comments stay; an older rSshTerm line is moved, never doubled).
    public static func preferring(in text: String?) -> String {
        let lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { line in
            let entry = line.trimmingCharacters(in: .whitespaces)
            return entry.split(separator: ":").first.map(String.init) != desktopID
        }
        let firstEntry = kept.firstIndex { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        } ?? kept.lastIndex { !$0.isEmpty }.map { $0 + 1 } ?? 0
        var result = kept
        result.insert(desktopID, at: firstEntry)
        var joined = result.joined(separator: "\n")
        if !joined.hasSuffix("\n") { joined += "\n" }
        return joined
    }

    /// The lists to write: the general one, and the desktop-specific ones that exist (xdg-terminal-exec reads those
    /// first, so a GNOME list naming another terminal would win otherwise).
    public func listPaths(exists: (String) -> Bool) -> [String] {
        let specific = desktops.map { "\(configHome)/\($0)-xdg-terminals.list" }.filter(exists)
        return specific + ["\(configHome)/xdg-terminals.list"]
    }

    var savedStatePath: String { "\(configHome)/rssh/default-terminal-undo.json" }

    // MARK: State

    /// What was there before Make Default: each list's text (nil: no file), the GNOME keys, the ssh:// handler.
    public struct Previous: Codable, Equatable, Sendable {
        public var lists: [String: String?]
        public var gnomeExec: String?
        public var gnomeExecArg: String?
        public var sshHandler: String?
    }

    public var canUndo: Bool { FileManager.default.fileExists(atPath: savedStatePath) }

    /// rSshTerm is first in the lists xdg-terminal-exec reads.
    public func isDefault() -> Bool {
        let paths = listPaths(exists: { FileManager.default.fileExists(atPath: $0) })
        guard let first = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = try? String(contentsOfFile: first, encoding: .utf8) else { return false }
        return Self.isPreferred(in: text)
    }

    public func makeDefault(executable: String) async throws {
        let fm = FileManager.default
        let paths = listPaths(exists: { fm.fileExists(atPath: $0) })
        if !canUndo {
            var previous = Previous(lists: [:])
            for path in paths { previous.lists[path] = .some(try? String(contentsOfFile: path, encoding: .utf8)) }
            if let gsettings, await hasGnomeSchema(gsettings) {
                previous.gnomeExec = try? await read(gsettings, ["get", Self.gnomeSchema, "exec"])
                previous.gnomeExecArg = try? await read(gsettings, ["get", Self.gnomeSchema, "exec-arg"])
            }
            if let xdgMime { previous.sshHandler = try? await read(xdgMime, ["query", "default", Self.sshScheme]) }
            try fm.createDirectory(atPath: (savedStatePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try JSONEncoder().encode(previous).write(to: URL(fileURLWithPath: savedStatePath), options: .atomic)
        }
        try fm.createDirectory(atPath: configHome, withIntermediateDirectories: true)
        for path in paths {
            let text = try? String(contentsOfFile: path, encoding: .utf8)
            try Self.preferring(in: text).write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let gsettings, await hasGnomeSchema(gsettings) {
            _ = try await runner.run(gsettings, ["set", Self.gnomeSchema, "exec", executable])
            _ = try await runner.run(gsettings, ["set", Self.gnomeSchema, "exec-arg", "-e"])
        }
        if let xdgMime { _ = try await runner.run(xdgMime, ["default", Self.desktopID, Self.sshScheme]) }
    }

    public func undo() async throws {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: savedStatePath),
              let previous = try? JSONDecoder().decode(Previous.self, from: data) else { return }
        for (path, text) in previous.lists {
            if let text { try text.write(toFile: path, atomically: true, encoding: .utf8) } else { try? fm.removeItem(atPath: path) }
        }
        if let gsettings, await hasGnomeSchema(gsettings) {
            // gsettings prints strings quoted ('gnome-terminal'); set takes them as GVariant text, so they go back as is.
            if let exec = previous.gnomeExec { _ = try await runner.run(gsettings, ["set", Self.gnomeSchema, "exec", exec]) }
            else { _ = try await runner.run(gsettings, ["reset", Self.gnomeSchema, "exec"]) }
            if let arg = previous.gnomeExecArg { _ = try await runner.run(gsettings, ["set", Self.gnomeSchema, "exec-arg", arg]) }
            else { _ = try await runner.run(gsettings, ["reset", Self.gnomeSchema, "exec-arg"]) }
        }
        if let xdgMime, let handler = previous.sshHandler, !handler.isEmpty, handler != Self.desktopID {
            _ = try await runner.run(xdgMime, ["default", handler, Self.sshScheme])
        }
        try fm.removeItem(atPath: savedStatePath)
    }

    private func hasGnomeSchema(_ gsettings: String) async -> Bool {
        guard let out = try? await runner.run(gsettings, ["list-schemas"]), out.status == 0 else { return false }
        return out.output.split(whereSeparator: \.isNewline).contains { $0 == Self.gnomeSchema }
    }

    private func read(_ tool: String, _ args: [String]) async throws -> String? {
        let out = try await runner.run(tool, args)
        guard out.status == 0 else { return nil }
        let value = out.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
