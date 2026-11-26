import Foundation

public enum InstallOutcome: Equatable, Sendable {
    /// Installed; the relaunch helper waits for this process to exit and starts the new build. The app quits now.
    case relaunching(executable: String)
    /// Paste this in a terminal (no pkexec).
    case showCommand(String)
    /// The user dismissed the password prompt.
    case cancelled
    case manual(reason: String)
}

/// Carries out an `UpdatePlan`: apt through pkexec, or download + SHA-256 check + atomic swap for a tarball or a
/// macOS bundle, then relaunch. Each swap renames inside the install's parent directory (same filesystem), keeps
/// the old copy until the new one is in place, and puts it back if the move fails.
public struct UpdateInstaller: Sendable {
    public struct Tools: Sendable {
        public var tar = "/usr/bin/tar"
        public var shell = "/bin/sh"
        public var hdiutil = "/usr/bin/hdiutil"
        public var ditto = "/usr/bin/ditto"
        public var codesign = "/usr/bin/codesign"
        public var open = "/usr/bin/open"

        public init() {}
    }

    public let checker: UpdateChecker
    public let runner: any ProcessRunner
    public let tools: Tools
    /// This process: the relaunch helper waits for it to exit.
    public let currentPID: Int32
    /// What to start after an apt upgrade (the app's own executable).
    public let relaunchExecutable: String

    public init(checker: UpdateChecker, runner: any ProcessRunner = FoundationProcessRunner(), tools: Tools = Tools(),
                currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                relaunchExecutable: String = CommandLine.arguments.first ?? InstallKind.executableName) {
        self.checker = checker
        self.runner = runner
        self.tools = tools
        self.currentPID = currentPID
        self.relaunchExecutable = relaunchExecutable
    }

    public func install(_ update: AvailableUpdate, plan: UpdatePlan) async throws(UpdateError) -> InstallOutcome {
        switch plan {
        case .showCommand(let command):
            return .showCommand(command)
        case .manual(let reason):
            return .manual(reason: reason)
        case .runPrivileged(let argv):
            return try await runPrivileged(argv)
        case .replaceTarball(let root):
            return try await replaceTarball(update, root: root)
        case .replaceMacApp(let bundle):
            return try await replaceMacApp(update, bundle: bundle)
        case .replaceAppImage(let file):
            return try await replaceAppImage(update, file: file)
        }
    }

    // MARK: AppImage

    /// Downloaded (SHA-256 checked) into a staging directory next to the file, made executable, then renamed over it:
    /// one atomic rename, so the file is always either the old or the new image. The running copy keeps its mounted
    /// image until it quits.
    private func replaceAppImage(_ update: AvailableUpdate, file: URL) async throws(UpdateError) -> InstallOutcome {
        let staging = try makeStaging(next: file)
        defer { try? FileManager.default.removeItem(at: staging) }
        let image = try await checker.download(update, into: staging)
        guard chmod(image.path, 0o755) == 0 else { throw .installFailed("chmod \(image.path): errno \(errno)") }
        guard rename(image.path, file.path) == 0 else {
            throw .installFailed("rename over \(file.path): \(String(cString: strerror(errno)))")
        }
        try relaunch(file.path, mac: false)
        return .relaunching(executable: file.path)
    }

    // MARK: apt

    private func runPrivileged(_ argv: [String]) async throws(UpdateError) -> InstallOutcome {
        guard let executable = argv.first else { throw .installFailed("empty command") }
        let result = try await run(executable, Array(argv.dropFirst()))
        switch result.status {
        case 0:
            try relaunch(relaunchExecutable, mac: false)
            return .relaunching(executable: relaunchExecutable)
        case 126, 127: // pkexec: dialog dismissed / not authorized
            return .cancelled
        default:
            throw .installFailed("apt-get exited \(result.status): \(Self.tail(result.output))")
        }
    }

    // MARK: tarball

    private func replaceTarball(_ update: AvailableUpdate, root: URL) async throws(UpdateError) -> InstallOutcome {
        let staging = try makeStaging(next: root)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = try await checker.download(update, into: staging)
        let unpacked = staging.appendingPathComponent("unpacked")
        try createDirectory(unpacked)
        let result = try await run(tools.tar, ["-xzf", archive.path, "-C", unpacked.path, "--no-same-owner"])
        guard result.status == 0 else { throw .installFailed("tar exited \(result.status): \(Self.tail(result.output))") }
        let newRoot = try Self.singleTopDirectory(unpacked) ?? unpacked
        let binary = newRoot.appendingPathComponent("bin/\(InstallKind.executableName)")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw .installFailed("the archive has no bin/\(InstallKind.executableName)")
        }
        try swap(newRoot, into: root, staging: staging)
        let executable = root.appendingPathComponent("bin/\(InstallKind.executableName)").path
        try relaunch(executable, mac: false)
        return .relaunching(executable: executable)
    }

    // MARK: macOS

    private func replaceMacApp(_ update: AvailableUpdate, bundle: URL) async throws(UpdateError) -> InstallOutcome {
        let staging = try makeStaging(next: bundle)
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = try await checker.download(update, into: staging)
        let unpacked = staging.appendingPathComponent("unpacked")
        try createDirectory(unpacked)

        if file.pathExtension.lowercased() == "zip" {
            let result = try await run(tools.ditto, ["-x", "-k", file.path, unpacked.path])
            guard result.status == 0 else { throw .installFailed("ditto exited \(result.status): \(Self.tail(result.output))") }
        } else {
            let mount = staging.appendingPathComponent("mount")
            try createDirectory(mount)
            let attach = try await run(tools.hdiutil, ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint",
                                                       mount.path, file.path])
            guard attach.status == 0 else { throw .installFailed("hdiutil attach: \(Self.tail(attach.output))") }
            do {
                guard let app = try Self.findApp(in: mount) else { throw UpdateError.installFailed("no .app in the disk image") }
                let copy = try await run(tools.ditto, [app.path, unpacked.appendingPathComponent(app.lastPathComponent).path])
                guard copy.status == 0 else { throw UpdateError.installFailed("ditto: \(Self.tail(copy.output))") }
            } catch {
                _ = try? await runner.run(tools.hdiutil, ["detach", mount.path, "-force"])
                throw (error as? UpdateError) ?? .installFailed("\(error)")
            }
            _ = try? await runner.run(tools.hdiutil, ["detach", mount.path, "-force"])
        }

        guard let newApp = try Self.findApp(in: unpacked) else { throw .installFailed("no .app in the download") }
        let verify = try await run(tools.codesign, ["--verify", "--deep", "--strict", newApp.path])
        guard verify.status == 0 else { throw .installFailed("code signature: \(Self.tail(verify.output))") }
        try swap(newApp, into: bundle, staging: staging)
        try relaunch(bundle.path, mac: true)
        return .relaunching(executable: bundle.path)
    }

    // MARK: shared steps

    /// A private staging directory next to `target` (same filesystem, so the swap is two renames).
    private func makeStaging(next target: URL) throws(UpdateError) -> URL {
        let staging = target.deletingLastPathComponent().appendingPathComponent(".rsshterm-update-\(UUID().uuidString)")
        try createDirectory(staging)
        return staging
    }

    private func createDirectory(_ url: URL) throws(UpdateError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw .installFailed("mkdir \(url.path): \(error)") }
    }

    /// `target` → backup, `replacement` → `target`, backup deleted; the backup goes back if the second move fails.
    private func swap(_ replacement: URL, into target: URL, staging: URL) throws(UpdateError) {
        let fm = FileManager.default
        let backup = staging.appendingPathComponent("previous")
        do { try fm.moveItem(at: target, to: backup) } catch { throw .installFailed("move \(target.path) aside: \(error)") }
        do {
            try fm.moveItem(at: replacement, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target)
            throw .installFailed("move the new build into \(target.path): \(error)")
        }
        try? fm.removeItem(at: backup)
    }

    /// The helper waits for this process to exit, then starts the new build (`open` for a bundle).
    private func relaunch(_ target: String, mac: Bool) throws(UpdateError) {
        let start = mac ? "exec \(tools.open) \"$2\"" : "exec \"$2\""
        let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; \(start)"
        do {
            try runner.launchDetached(tools.shell, ["-c", script, "rsshterm-relaunch", String(currentPID), target])
        } catch { throw .installFailed("relaunch: \(error)") }
    }

    private func run(_ executable: String, _ arguments: [String]) async throws(UpdateError) -> ProcessOutput {
        do { return try await runner.run(executable, arguments) } catch {
            throw .installFailed("\(executable): \(error)")
        }
    }

    static func singleTopDirectory(_ directory: URL) throws(UpdateError) -> URL? {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        } catch { throw .installFailed("read \(directory.path): \(error)") }
        guard entries.count == 1, (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        return entries[0]
    }

    static func findApp(in directory: URL) throws(UpdateError) -> URL? {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
        } catch { throw .installFailed("read \(directory.path): \(error)") }
    }

    static func tail(_ text: String, lines: Int = 5) -> String {
        text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
