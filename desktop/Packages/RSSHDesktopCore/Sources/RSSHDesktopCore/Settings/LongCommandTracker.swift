import Foundation

/// "Notify when a long command finishes": fed the foreground program of each local pane about once a second
/// (`ForegroundProcess.localFacts`, nil while the shell waits at its prompt), it says which program just ended and
/// how long it ran. A value type: every update returns the finished command, if any, and keeps the rest.
public struct LongCommandTracker: Sendable {
    public struct Finished: Equatable, Sendable {
        public let pane: PaneID
        /// The command line, as `argv` joined with spaces.
        public let command: String
        public let seconds: Int

        public init(pane: PaneID, command: String, seconds: Int) {
            self.pane = pane
            self.command = command
            self.seconds = seconds
        }
    }

    private var running: [PaneID: (command: [String], since: Date)] = [:]

    public init() {}

    /// The pane's foreground program now. A program that is gone (back at the prompt, or another one in front) is
    /// returned as finished.
    public mutating func update(_ pane: PaneID, foreground: [String]?, at now: Date) -> Finished? {
        let previous = running[pane]
        if let previous, previous.command == foreground { return nil }
        running[pane] = foreground.flatMap { $0.isEmpty ? nil : ($0, now) }
        guard let previous else { return nil }
        return Finished(pane: pane, command: previous.command.joined(separator: " "),
                        seconds: Int(now.timeIntervalSince(previous.since).rounded()))
    }

    public mutating func forget(_ pane: PaneID) { running[pane] = nil }

    /// Worth a notification: it ran at least `threshold` seconds and nobody was looking at it (the app was in the
    /// background, or the pane was not on screen).
    public static func shouldNotify(_ finished: Finished, threshold: Int, appActive: Bool, paneVisible: Bool) -> Bool {
        finished.seconds >= threshold && !(appActive && paneVisible)
    }
}

/// The terminal cursor's shape (Settings › Terminal); blinking is a separate switch.
public enum TerminalCursorStyle: String, Codable, CaseIterable, Sendable {
    case block, bar, underline

    public var title: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        }
    }
}
