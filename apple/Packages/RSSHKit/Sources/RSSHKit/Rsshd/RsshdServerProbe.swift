import Foundation

/// `rsshd doctor --json`: `{version, healthy, missing, report:{os, tmux_version, checks:[…]}}`.
public struct RsshdDoctorReport: Decodable, Equatable, Sendable {
    public struct Check: Decodable, Equatable, Sendable {
        public var name: String
        public var ok: Bool
        public var required: Bool
        public var detail: String
        public var fix: String

        private enum CodingKeys: String, CodingKey { case name, ok, required, detail, fix }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lenient(String.self, .name) ?? ""
            ok = c.lenient(Bool.self, .ok) ?? false
            required = c.lenient(Bool.self, .required) ?? false
            detail = c.lenient(String.self, .detail) ?? ""
            fix = c.lenient(String.self, .fix) ?? ""
        }
    }

    private struct Report: Decodable {
        var os: String?
        var checks: [Check]?
    }

    public var version: String
    public var missing: [String]
    public var os: String
    public var checks: [Check]

    private enum CodingKeys: String, CodingKey { case version, missing, report }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(String.self, .version) ?? ""
        missing = c.lenient([String].self, .missing) ?? []
        let report = c.lenient(Report.self, .report)
        os = report?.os ?? ""
        checks = report?.checks ?? []
    }

    public func check(_ name: String) -> Check? { checks.first { $0.name == name } }
}

/// What `RsshdCommands.check` found on a server.
public struct RsshdServerProbe: Equatable, Sendable {
    /// "linux", "darwin", or "" when unknown.
    public var os: String
    public var hasApt: Bool
    /// Where rsshd is; nil when it is not installed.
    public var rsshdPath: String?
    public var doctor: RsshdDoctorReport?

    public init(os: String = "", hasApt: Bool = false, rsshdPath: String? = nil, doctor: RsshdDoctorReport? = nil) {
        self.os = os
        self.hasApt = hasApt
        self.rsshdPath = rsshdPath
        self.doctor = doctor
    }

    public var isInstalled: Bool { rsshdPath != nil }
    /// Installed by the .deb (apt upgrades it), not install.sh --tarball (~/.local/bin).
    public var isFromApt: Bool { rsshdPath == "/usr/bin/rsshd" }

    /// Reads `uname:`, `apt:` and `rsshd:` lines, then the doctor JSON from the first line starting with "{".
    public static func parse(_ output: String) -> RsshdServerProbe {
        var probe = RsshdServerProbe()
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if line.hasPrefix("uname:") { probe.os = line.dropFirst(6).trimmingCharacters(in: .whitespaces).lowercased() }
            if line == "apt:yes" { probe.hasApt = true }
            if line.hasPrefix("rsshd:") { probe.rsshdPath = String(line.dropFirst(6)) }
        }
        if let start = lines.firstIndex(where: { $0.hasPrefix("{") }) {
            let json = lines[start...].joined(separator: "\n")
            probe.doctor = try? JSONDecoder().decode(RsshdDoctorReport.self, from: Data(json.utf8))
        }
        return probe
    }
}

/// A backend on the status sheet: usable, or shown disabled with the reason.
public struct RsshdBackendRow: Equatable, Sendable, Identifiable {
    public var backend: SessionBackend
    public var version: String?
    /// Why it cannot be used; nil when it can.
    public var why: String?
    public var id: SessionBackend { backend }
    public var isAvailable: Bool { why == nil }

    public init(backend: SessionBackend, version: String?, why: String?) {
        self.backend = backend
        self.version = version
        self.why = why
    }

    /// tmux and screen as `hello` reports them.
    public static func rows(hello: RsshdHello) -> [RsshdBackendRow] {
        [SessionBackend.tmux, .screen].map { backend in
            if let version = hello.backends[backend.rawValue] {
                return RsshdBackendRow(backend: backend, version: version, why: nil)
            }
            let why = hello.missing.contains(backend.rawValue)
                ? "\(backend.rawValue) is not installed on the server"
                : "this rSshD has no \(backend.rawValue) backend"
            return RsshdBackendRow(backend: backend, version: nil, why: why)
        }
    }
}

/// The "Sessions not kept" chip shows at most once per server per day, so a server without rsshd does not nag.
public enum RsshdChipThrottle {
    public static func shouldShowMissing(lastShown: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastShown else { return true }
        return !calendar.isDate(lastShown, inSameDayAs: now)
    }
}
