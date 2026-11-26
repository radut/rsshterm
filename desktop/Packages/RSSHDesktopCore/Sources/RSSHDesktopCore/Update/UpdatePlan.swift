import Foundation

/// How this copy of the app was installed, which decides how it updates.
public enum InstallKind: Equatable, Sendable {
    /// The .deb from the apt repo (dpkg knows package `rsshterm`).
    case apt
    /// An unpacked tarball: `<root>/bin/rsshterm`.
    case tarball(root: URL)
    /// A macOS bundle.
    case macApp(bundle: URL)
    /// An AppImage: the file `$APPIMAGE` names (the running executable is inside its mounted image).
    case appImage(file: URL)
    /// A development build or an unknown layout: never replaced automatically.
    case unmanaged

    public static let debPackage = "rsshterm"
    public static let executableName = "rsshterm"

    /// From the running executable's path (and `$APPIMAGE`, set by the AppImage runtime). `fileExists` is injectable
    /// for tests.
    public static func detect(executable: URL, platform: Platform = .current,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> InstallKind {
        if platform == .linux, let image = environment["APPIMAGE"], image.hasPrefix("/") {
            return .appImage(file: URL(fileURLWithPath: image).standardizedFileURL)
        }
        // Inside a mounted AppImage without a usable $APPIMAGE: read-only, never replaced in place.
        if platform == .linux, executable.path.contains("/.mount_") { return .unmanaged }
        let path = executable.standardizedFileURL.path
        switch platform {
        case .macOS:
            var url = executable.standardizedFileURL
            while url.path != "/" {
                if url.pathExtension == "app" { return .macApp(bundle: URL(fileURLWithPath: url.path)) }
                url = url.deletingLastPathComponent()
            }
            return .unmanaged
        case .linux:
            if path.hasPrefix("/usr/"), fileExists("/var/lib/dpkg/info/\(debPackage).list") { return .apt }
            let bin = executable.standardizedFileURL.deletingLastPathComponent()
            guard bin.lastPathComponent == "bin", executable.lastPathComponent == executableName, !path.hasPrefix("/usr/")
            else { return .unmanaged }
            return .tarball(root: URL(fileURLWithPath: bin.deletingLastPathComponent().path))
        }
    }
}

/// What "update now" does for an install.
public enum UpdatePlan: Equatable, Sendable {
    /// Run this argv (pkexec + apt-get), then relaunch.
    case runPrivileged([String])
    /// No graphical sudo: show this command to paste in a terminal.
    case showCommand(String)
    case replaceTarball(root: URL)
    case replaceMacApp(bundle: URL)
    /// Download the new AppImage next to `file`, make it executable and rename it over `file`.
    case replaceAppImage(file: URL)
    /// Cannot update in place (unmanaged build, or no write access): say why and offer the download page.
    case manual(reason: String)
}

public enum UpdatePlanner {
    public static let aptShellCommand = "apt-get update && apt-get install -y \(InstallKind.debPackage)"

    /// `pkexecPath` is pkexec when installed (polkit's graphical sudo); `isWritable` checks the install's parent
    /// directory, since the swap renames inside it.
    public static func plan(for kind: InstallKind, pkexecPath: String?,
                            isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }) -> UpdatePlan {
        switch kind {
        case .apt:
            if let pkexecPath { return .runPrivileged([pkexecPath, "/bin/sh", "-c", aptShellCommand]) }
            return .showCommand("sudo apt-get update && sudo apt-get install -y \(InstallKind.debPackage)")
        case .tarball(let root):
            guard isWritable(root.deletingLastPathComponent()), isWritable(root) else {
                return .manual(reason: "No write access to \(root.path).")
            }
            return .replaceTarball(root: root)
        case .macApp(let bundle):
            guard isWritable(bundle.deletingLastPathComponent()) else {
                return .manual(reason: "No write access to \(bundle.deletingLastPathComponent().path).")
            }
            return .replaceMacApp(bundle: bundle)
        case .appImage(let file):
            guard isWritable(file.deletingLastPathComponent()) else {
                return .manual(reason: "No write access to \(file.deletingLastPathComponent().path).")
            }
            return .replaceAppImage(file: file)
        case .unmanaged:
            return .manual(reason: "This build was not installed from a release.")
        }
    }

    /// pkexec on PATH-independent standard locations.
    public static func findPkexec(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> String? {
        ["/usr/bin/pkexec", "/bin/pkexec"].first(where: fileExists)
    }
}
