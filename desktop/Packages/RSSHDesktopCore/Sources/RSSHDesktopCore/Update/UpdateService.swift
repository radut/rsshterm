import Foundation

/// When to look for updates: at launch (unless checked within the last hour) and then once a day; "Check for
/// Updates" in the menu always checks.
public struct UpdateSchedule: Equatable, Sendable {
    public var interval: TimeInterval = 24 * 60 * 60
    public var launchGrace: TimeInterval = 60 * 60

    public init() {}

    public func isDue(lastCheck: Date?, now: Date, atLaunch: Bool) -> Bool {
        guard let lastCheck else { return true }
        guard now >= lastCheck else { return true } // the clock went back: check rather than wait for ever
        return now.timeIntervalSince(lastCheck) >= (atLaunch ? launchGrace : interval)
    }

    public func nextCheck(after lastCheck: Date) -> Date { lastCheck.addingTimeInterval(interval) }
}

/// Check for Updates, from the menu or the timer: reads latest.json and, when a newer build exists and
/// `autoInstall` is on, triggers the upgrade (apt via pkexec, tarball or bundle swap, then relaunch).
public actor UpdateService {
    public enum Trigger: Sendable { case launch, periodic, manual }

    public enum Outcome: Equatable, Sendable {
        /// Checked recently; nothing done.
        case notDue
        case upToDate(latest: SemanticVersion)
        /// Newer build found; auto-install is off, so the app offers it.
        case available(AvailableUpdate)
        case installed(AvailableUpdate, InstallOutcome)
    }

    private let current: SemanticVersion
    private let assetKey: String
    private let plan: UpdatePlan
    private let installer: UpdateInstaller
    private let schedule: UpdateSchedule
    private let autoInstall: Bool
    private let now: @Sendable () -> Date
    private let loadLastCheck: @Sendable () -> Date?
    private let saveLastCheck: @Sendable (Date) -> Void
    private var running = false

    public init(current: SemanticVersion, assetKey: String, plan: UpdatePlan, installer: UpdateInstaller,
                schedule: UpdateSchedule = UpdateSchedule(), autoInstall: Bool = true,
                now: @escaping @Sendable () -> Date = { Date() },
                loadLastCheck: @escaping @Sendable () -> Date?, saveLastCheck: @escaping @Sendable (Date) -> Void) {
        self.current = current
        self.assetKey = assetKey
        self.plan = plan
        self.installer = installer
        self.schedule = schedule
        self.autoInstall = autoInstall
        self.now = now
        self.loadLastCheck = loadLastCheck
        self.saveLastCheck = saveLastCheck
    }

    public func run(_ trigger: Trigger) async throws(UpdateError) -> Outcome {
        let time = now()
        if trigger != .manual, !schedule.isDue(lastCheck: loadLastCheck(), now: time, atLaunch: trigger == .launch) {
            return .notDue
        }
        guard !running else { return .notDue } // one check or install at a time
        running = true
        defer { running = false }
        let result = try await installer.checker.check(current: current, assetKey: assetKey)
        saveLastCheck(time)
        switch result {
        case .upToDate(let latest):
            return .upToDate(latest: latest)
        case .available(let update):
            // The menu item installs even with auto-install off: the user asked for it.
            guard autoInstall || trigger == .manual else { return .available(update) }
            return .installed(update, try await installer.install(update, plan: plan))
        }
    }
}
