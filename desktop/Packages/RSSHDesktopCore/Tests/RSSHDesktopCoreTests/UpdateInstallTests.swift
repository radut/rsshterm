import Foundation
import Synchronization
import Testing
@testable import RSSHDesktopCore

@Suite struct InstallKindTests {
    @Test func detection() {
        let dpkg: (String) -> Bool = { $0 == "/var/lib/dpkg/info/rsshterm.list" }
        #expect(InstallKind.detect(executable: URL(fileURLWithPath: "/usr/bin/rsshterm"), platform: .linux, fileExists: dpkg) == .apt)
        #expect(InstallKind.detect(executable: URL(fileURLWithPath: "/usr/bin/rsshterm"), platform: .linux, fileExists: { _ in false })
            == .unmanaged)
        #expect(InstallKind.detect(executable: URL(fileURLWithPath: "/home/u/.local/opt/rsshterm/bin/rsshterm"), platform: .linux,
                                   fileExists: dpkg) == .tarball(root: URL(fileURLWithPath: "/home/u/.local/opt/rsshterm")))
        #expect(InstallKind.detect(executable: URL(fileURLWithPath: "/home/u/src/.build/debug/rsshterm"), platform: .linux,
                                   fileExists: dpkg) == .unmanaged)
        #expect(InstallKind.detect(executable: URL(fileURLWithPath: "/Applications/rSshTerm.app/Contents/MacOS/rSshTerm"),
                                   platform: .macOS) == .macApp(bundle: URL(fileURLWithPath: "/Applications/rSshTerm.app")))
    }

    @Test func plans() {
        #expect(UpdatePlanner.plan(for: .apt, pkexecPath: "/usr/bin/pkexec")
            == .runPrivileged(["/usr/bin/pkexec", "/bin/sh", "-c", "apt-get update && apt-get install -y rsshterm"]))
        #expect(UpdatePlanner.plan(for: .apt, pkexecPath: nil)
            == .showCommand("sudo apt-get update && sudo apt-get install -y rsshterm"))
        let root = URL(fileURLWithPath: "/opt/rsshterm")
        #expect(UpdatePlanner.plan(for: .tarball(root: root), pkexecPath: nil, isWritable: { _ in true }) == .replaceTarball(root: root))
        guard case .manual = UpdatePlanner.plan(for: .tarball(root: root), pkexecPath: nil, isWritable: { _ in false }) else {
            Issue.record("read-only tarball should be manual"); return
        }
        let app = URL(fileURLWithPath: "/Applications/rSshTerm.app")
        #expect(UpdatePlanner.plan(for: .macApp(bundle: app), pkexecPath: nil, isWritable: { _ in true }) == .replaceMacApp(bundle: app))
        guard case .manual = UpdatePlanner.plan(for: .unmanaged, pkexecPath: "/usr/bin/pkexec") else { Issue.record("unmanaged"); return }
    }

    @Test func appImageDetectionPlanAndAssetKey() {
        let env = ["APPIMAGE": "/home/u/Apps/rSshTerm-x86_64.AppImage"]
        let mounted = URL(fileURLWithPath: "/tmp/.mount_rSshTeXYZ/usr/bin/rsshterm")
        let file = URL(fileURLWithPath: "/home/u/Apps/rSshTerm-x86_64.AppImage")
        #expect(InstallKind.detect(executable: mounted, platform: .linux, environment: env, fileExists: { _ in false })
            == .appImage(file: file))
        // a relative or empty APPIMAGE is ignored
        #expect(InstallKind.detect(executable: mounted, platform: .linux, environment: ["APPIMAGE": "x.AppImage"],
                                   fileExists: { _ in false }) == .unmanaged)
        #expect(UpdatePlanner.plan(for: .appImage(file: file), pkexecPath: nil, isWritable: { _ in true })
            == .replaceAppImage(file: file))
        guard case .manual = UpdatePlanner.plan(for: .appImage(file: file), pkexecPath: nil, isWritable: { _ in false }) else {
            Issue.record("read-only AppImage should be manual"); return
        }
        #expect(UpdatePlatformKey.key(for: .appImage(file: file), architecture: "x86_64") == "linux-amd64-appimage")
        #expect(UpdatePlatformKey.key(for: .appImage(file: file), architecture: "aarch64") == "linux-arm64-appimage")
        #expect(UpdatePlatformKey.key(for: .apt, architecture: "x86_64") == "linux-amd64")
        #expect(UpdatePlatformKey.key(for: .macApp(bundle: URL(fileURLWithPath: "/A.app")), architecture: "arm64") == "macos-universal")
    }

    @Test func schedule() {
        let schedule = UpdateSchedule()
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(schedule.isDue(lastCheck: nil, now: now, atLaunch: false))
        #expect(!schedule.isDue(lastCheck: now.addingTimeInterval(-30 * 60), now: now, atLaunch: true))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(-2 * 3600), now: now, atLaunch: true))
        #expect(!schedule.isDue(lastCheck: now.addingTimeInterval(-2 * 3600), now: now, atLaunch: false))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now, atLaunch: false))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now, atLaunch: false)) // clock went back
    }
}

@Suite(.serialized) struct UpdateInstallTests {
    private func update(_ feed: SignedFeed, key: String) async throws -> AvailableUpdate {
        guard case .available(let update) = try await feed.checker.check(current: SemanticVersion("1.0.0")!, assetKey: key)
        else { throw UpdateError.badManifest("no update") }
        return update
    }

    // MARK: apt

    @Test func aptRunsPkexecThenRelaunches() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64", fileName: "a.tar.gz", payload: Data("x".utf8))
        let runner = FakeRunner()
        let installer = UpdateInstaller(checker: feed.checker, runner: runner, currentPID: 4242, relaunchExecutable: "/usr/bin/rsshterm")
        let plan = UpdatePlanner.plan(for: .apt, pkexecPath: "/usr/bin/pkexec")
        let outcome = try await installer.install(try await update(feed, key: "linux-amd64"), plan: plan)
        #expect(outcome == .relaunching(executable: "/usr/bin/rsshterm"))
        #expect(runner.calls.withLock { $0 } == [["/usr/bin/pkexec", "/bin/sh", "-c", "apt-get update && apt-get install -y rsshterm"]])
        let helper = try #require(runner.detached.withLock { $0.first })
        #expect(helper.first == "/bin/sh")
        #expect(Array(helper.suffix(2)) == ["4242", "/usr/bin/rsshterm"])
    }

    @Test func aptDismissedPromptIsCancelledAndFailureIsReported() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64", fileName: "a.tar.gz", payload: Data("x".utf8))
        let plan = UpdatePlan.runPrivileged(["/usr/bin/pkexec", "/bin/sh", "-c", UpdatePlanner.aptShellCommand])
        let dismissed = FakeRunner { _, _ in ProcessOutput(status: 126, output: "") }
        let up = try await update(feed, key: "linux-amd64")
        #expect(try await UpdateInstaller(checker: feed.checker, runner: dismissed).install(up, plan: plan) == .cancelled)
        #expect(dismissed.detached.withLock { $0 }.isEmpty)
        let failing = FakeRunner { _, _ in ProcessOutput(status: 100, output: "E: Unable to locate package rsshterm") }
        await #expect(throws: UpdateError.installFailed("apt-get exited 100: E: Unable to locate package rsshterm")) {
            _ = try await UpdateInstaller(checker: feed.checker, runner: failing).install(up, plan: plan)
        }
    }

    @Test func noPkexecShowsTheCommand() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64", fileName: "a.tar.gz", payload: Data("x".utf8))
        let runner = FakeRunner()
        let outcome = try await UpdateInstaller(checker: feed.checker, runner: runner)
            .install(try await update(feed, key: "linux-amd64"), plan: UpdatePlanner.plan(for: .apt, pkexecPath: nil))
        #expect(outcome == .showCommand("sudo apt-get update && sudo apt-get install -y rsshterm"))
        #expect(runner.calls.withLock { $0 }.isEmpty)
    }

    // MARK: tarball (real tar, real files)

    /// A runner that really runs tar (and anything else), recording the relaunch instead of starting it.
    private func realRunner() -> FakeRunner {
        FakeRunner { executable, arguments in
            let (status, output) = try run(executable, arguments)
            return ProcessOutput(status: status, output: output)
        }
    }

    private func makeTarball(version: String, in dir: String, withBinary: Bool = true) throws -> Data {
        let top = "\(dir)/build/rsshterm-\(version)-linux-amd64"
        try FileManager.default.createDirectory(atPath: "\(top)/bin", withIntermediateDirectories: true)
        if withBinary {
            try "#!/bin/sh\necho \(version)\n".write(toFile: "\(top)/bin/rsshterm", atomically: true, encoding: .utf8)
            chmod("\(top)/bin/rsshterm", 0o755)
        }
        try "\(version)".write(toFile: "\(top)/VERSION", atomically: true, encoding: .utf8)
        let archive = "\(dir)/rsshterm.tar.gz"
        #expect(try run("/usr/bin/tar", ["-czf", archive, "-C", "\(dir)/build", "rsshterm-\(version)-linux-amd64"]).0 == 0)
        try FileManager.default.removeItem(atPath: "\(dir)/build")
        return try Data(contentsOf: URL(fileURLWithPath: archive))
    }

    private func installOld(at root: String) throws {
        try FileManager.default.createDirectory(atPath: "\(root)/bin", withIntermediateDirectories: true)
        try "#!/bin/sh\necho old\n".write(toFile: "\(root)/bin/rsshterm", atomically: true, encoding: .utf8)
        chmod("\(root)/bin/rsshterm", 0o755)
        try "old".write(toFile: "\(root)/OLD-ONLY", atomically: true, encoding: .utf8)
    }

    @Test func tarballIsReplacedInPlaceAndRelaunched() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let root = "\(dir.path)/opt/rsshterm"
        try installOld(at: root)
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64", fileName: "rsshterm-1.1.0-linux-amd64.tar.gz",
                         payload: try makeTarball(version: "1.1.0", in: dir.path))
        let runner = realRunner()
        let installer = UpdateInstaller(checker: feed.checker, runner: runner, currentPID: 99)
        let plan = UpdatePlanner.plan(for: .tarball(root: URL(fileURLWithPath: root)), pkexecPath: nil)
        let outcome = try await installer.install(try await update(feed, key: "linux-amd64"), plan: plan)

        #expect(outcome == .relaunching(executable: "\(root)/bin/rsshterm"))
        #expect(try String(contentsOfFile: "\(root)/VERSION", encoding: .utf8) == "1.1.0")
        #expect(!FileManager.default.fileExists(atPath: "\(root)/OLD-ONLY"))
        #expect(try run("\(root)/bin/rsshterm", []).1 == "1.1.0\n")
        // nothing left behind next to the install
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(dir.path)/opt") == ["rsshterm"])
        #expect(runner.detached.withLock { $0.first?.suffix(2) } == ["99", "\(root)/bin/rsshterm"])
    }

    @Test func badArchiveLeavesTheOldInstallAlone() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let root = "\(dir.path)/opt/rsshterm"
        try installOld(at: root)
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64", fileName: "a.tar.gz",
                         payload: try makeTarball(version: "1.1.0", in: dir.path, withBinary: false))
        let runner = realRunner()
        let plan = UpdatePlan.replaceTarball(root: URL(fileURLWithPath: root))
        await #expect(throws: UpdateError.installFailed("the archive has no bin/rsshterm")) {
            _ = try await UpdateInstaller(checker: feed.checker, runner: runner).install(try await update(feed, key: "linux-amd64"),
                                                                                         plan: plan)
        }
        #expect(FileManager.default.fileExists(atPath: "\(root)/OLD-ONLY"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(dir.path)/opt") == ["rsshterm"])
        #expect(runner.detached.withLock { $0 }.isEmpty)
    }

    @Test func checksumMismatchNeverTouchesTheInstall() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let root = "\(dir.path)/opt/rsshterm"
        try installOld(at: root)
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64", fileName: "a.tar.gz",
                         payload: try makeTarball(version: "1.1.0", in: dir.path), sha256: String(repeating: "0", count: 64))
        let runner = realRunner()
        await #expect(throws: UpdateError.self) {
            _ = try await UpdateInstaller(checker: feed.checker, runner: runner)
                .install(try await update(feed, key: "linux-amd64"), plan: .replaceTarball(root: URL(fileURLWithPath: root)))
        }
        #expect(runner.calls.withLock { $0 }.isEmpty) // tar never ran
        #expect(FileManager.default.fileExists(atPath: "\(root)/OLD-ONLY"))
    }

    // MARK: AppImage

    @Test func appImageIsReplacedAtomicallyAndRelaunched() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let apps = "\(dir.path)/Apps"
        try FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: true)
        let target = "\(apps)/rSshTerm-x86_64.AppImage"
        try "#!/bin/sh\necho old\n".write(toFile: target, atomically: true, encoding: .utf8)
        chmod(target, 0o755)
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64-appimage", fileName: "rSshTerm-1.1.0-x86_64.AppImage",
                         payload: Data("#!/bin/sh\necho 1.1.0\n".utf8))
        let runner = realRunner()
        let installer = UpdateInstaller(checker: feed.checker, runner: runner, currentPID: 77)
        let outcome = try await installer.install(try await update(feed, key: "linux-amd64-appimage"),
                                                  plan: .replaceAppImage(file: URL(fileURLWithPath: target)))
        #expect(outcome == .relaunching(executable: target))
        #expect(try run(target, []).1 == "1.1.0\n")
        #expect(FileManager.default.isExecutableFile(atPath: target))
        #expect(try FileManager.default.contentsOfDirectory(atPath: apps) == ["rSshTerm-x86_64.AppImage"])
        #expect(runner.detached.withLock { $0.first?.suffix(2) } == ["77", target])
    }

    @Test func appImageChecksumMismatchKeepsTheOldFile() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let target = "\(dir.path)/rSshTerm.AppImage"
        try "old".write(toFile: target, atomically: true, encoding: .utf8)
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64-appimage", fileName: "n.AppImage",
                         payload: Data("new".utf8), sha256: String(repeating: "0", count: 64))
        let runner = realRunner()
        await #expect(throws: UpdateError.self) {
            _ = try await UpdateInstaller(checker: feed.checker, runner: runner)
                .install(try await update(feed, key: "linux-amd64-appimage"), plan: .replaceAppImage(file: URL(fileURLWithPath: target)))
        }
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["rSshTerm.AppImage"])
        #expect(runner.detached.withLock { $0 }.isEmpty)
    }

    // MARK: macOS (hdiutil/ditto/codesign simulated)

    private func macRunner(codesignStatus: Int32 = 0) -> FakeRunner {
        FakeRunner { executable, arguments in
            let fm = FileManager.default
            switch (executable as NSString).lastPathComponent {
            case "hdiutil" where arguments.first == "attach":
                let mount = arguments[arguments.firstIndex(of: "-mountpoint")! + 1]
                try fm.createDirectory(atPath: "\(mount)/rSshTerm.app/Contents/MacOS", withIntermediateDirectories: true)
                try "new".write(toFile: "\(mount)/rSshTerm.app/Contents/MacOS/rSshTerm", atomically: true, encoding: .utf8)
                try fm.createSymbolicLink(atPath: "\(mount)/Applications", withDestinationPath: "/Applications")
            case "ditto" where arguments.first == "-x":
                try fm.createDirectory(atPath: "\(arguments[3])/rSshTerm.app/Contents/MacOS", withIntermediateDirectories: true)
                try "new-zip".write(toFile: "\(arguments[3])/rSshTerm.app/Contents/MacOS/rSshTerm", atomically: true, encoding: .utf8)
            case "ditto":
                try fm.copyItem(atPath: arguments[0], toPath: arguments[1])
            case "codesign":
                return ProcessOutput(status: codesignStatus, output: codesignStatus == 0 ? "" : "invalid signature")
            default:
                break
            }
            return ProcessOutput(status: 0, output: "")
        }
    }

    private func installOldApp(in dir: String) throws -> String {
        let app = "\(dir)/Applications/rSshTerm.app"
        try FileManager.default.createDirectory(atPath: "\(app)/Contents/MacOS", withIntermediateDirectories: true)
        try "old".write(toFile: "\(app)/Contents/MacOS/rSshTerm", atomically: true, encoding: .utf8)
        return app
    }

    @Test(arguments: ["rSshTerm-1.1.0.dmg", "rSshTerm-1.1.0.zip"])
    func macBundleIsReplacedAndReopened(_ fileName: String) async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let app = try installOldApp(in: dir.path)
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "macos-universal", fileName: fileName, payload: Data("image".utf8))
        let runner = macRunner()
        let installer = UpdateInstaller(checker: feed.checker, runner: runner, currentPID: 7)
        let outcome = try await installer.install(try await update(feed, key: "macos-universal"),
                                                  plan: .replaceMacApp(bundle: URL(fileURLWithPath: app)))
        #expect(outcome == .relaunching(executable: app))
        let binary = try String(contentsOfFile: "\(app)/Contents/MacOS/rSshTerm", encoding: .utf8)
        #expect(binary == (fileName.hasSuffix(".zip") ? "new-zip" : "new"))
        let calls = runner.calls.withLock { $0 }.map { ($0[0] as NSString).lastPathComponent + " " + ($0.dropFirst().first ?? "") }
        if fileName.hasSuffix(".dmg") {
            #expect(calls.first == "hdiutil attach")
            #expect(calls.contains("hdiutil detach"))
        }
        #expect(calls.last == "codesign --verify")
        let helper = try #require(runner.detached.withLock { $0.first })
        #expect(helper[2].contains("/usr/bin/open"))
        #expect(Array(helper.suffix(2)) == ["7", app])
        #expect(try FileManager.default.contentsOfDirectory(atPath: "\(dir.path)/Applications") == ["rSshTerm.app"])
    }

    @Test func macBadSignatureKeepsTheOldApp() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let app = try installOldApp(in: dir.path)
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "macos-universal", fileName: "a.dmg", payload: Data("image".utf8))
        let runner = macRunner(codesignStatus: 1)
        await #expect(throws: UpdateError.installFailed("code signature: invalid signature")) {
            _ = try await UpdateInstaller(checker: feed.checker, runner: runner)
                .install(try await update(feed, key: "macos-universal"), plan: .replaceMacApp(bundle: URL(fileURLWithPath: app)))
        }
        #expect(try String(contentsOfFile: "\(app)/Contents/MacOS/rSshTerm", encoding: .utf8) == "old")
        #expect(runner.detached.withLock { $0 }.isEmpty)
    }

    // MARK: service: check + trigger

    @Test func serviceChecksWhenDueAndTriggersTheUpgrade() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64", fileName: "a.tar.gz", payload: Data("x".utf8))
        let runner = FakeRunner()
        let last = Mutex<Date?>(nil)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let service = UpdateService(current: SemanticVersion("1.0.0")!, assetKey: "linux-amd64",
                                    plan: UpdatePlanner.plan(for: .apt, pkexecPath: "/usr/bin/pkexec"),
                                    installer: UpdateInstaller(checker: feed.checker, runner: runner, relaunchExecutable: "/usr/bin/rsshterm"),
                                    now: { now }, loadLastCheck: { last.withLock { $0 } },
                                    saveLastCheck: { date in last.withLock { $0 = date } })
        let outcome = try await service.run(.launch)
        guard case .installed(let update, .relaunching) = outcome else { Issue.record("\(outcome)"); return }
        #expect(update.version == SemanticVersion("1.1.0"))
        #expect(last.withLock { $0 } == now)
        #expect(runner.calls.withLock { $0 }.count == 1)
        #expect(try await service.run(.periodic) == .notDue) // just checked
    }

    @Test func serviceWithoutAutoInstallOnlyReportsButMenuInstalls() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64", fileName: "a.tar.gz", payload: Data("x".utf8))
        let runner = FakeRunner()
        let service = UpdateService(current: SemanticVersion("1.0.0")!, assetKey: "linux-amd64",
                                    plan: .runPrivileged(["/usr/bin/pkexec", "true"]),
                                    installer: UpdateInstaller(checker: feed.checker, runner: runner), autoInstall: false,
                                    loadLastCheck: { nil }, saveLastCheck: { _ in })
        guard case .available = try await service.run(.periodic) else { Issue.record("expected available"); return }
        #expect(runner.calls.withLock { $0 }.isEmpty)
        guard case .installed(_, .relaunching) = try await service.run(.manual) else { Issue.record("menu should install"); return }
    }

    @Test func serviceUpToDate() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "1.0.0", assetKey: "linux-amd64", fileName: "a.tar.gz", payload: Data("x".utf8))
        let service = UpdateService(current: SemanticVersion("1.0.0")!, assetKey: "linux-amd64", plan: .manual(reason: ""),
                                    installer: UpdateInstaller(checker: feed.checker, runner: FakeRunner()),
                                    loadLastCheck: { Date() }, saveLastCheck: { _ in })
        #expect(try await service.run(.manual) == .upToDate(latest: SemanticVersion("1.0.0")!))
    }
}
