// swift-tools-version: 6.0
// RSSHDesktopCore: the platform-neutral core of the desktop rSshTerm (Linux and macOS): window/tab/split layout,
// keybindings, host search, local PTY, the built-in ssh-agent, the updater, and the view models of the server
// list, server editor, file manager (commander, transfers, remote edit), Quick Connect and network scan. No
// AppKit/GTK, so `swift test` runs on Linux (swift:6.4-noble) and on the Mac. Shares models, vault and agent code with the iOS app through RSSHKit.
import PackageDescription

let package = Package(
    name: "RSSHDesktopCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RSSHDesktopCore", targets: ["RSSHDesktopCore"]),
    ],
    dependencies: [
        .package(path: "../../../apple/Packages/RSSHKit"),
        // SFTP, vault logins, host-key pinning and jump hosts on Citadel, shared with the iOS app.
        .package(path: "../../../apple/Packages/RSSHRemote"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        // forkpty + execve in C: nothing but async-signal-safe calls between fork and exec.
        .target(name: "CRSSHPTY", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
        .target(name: "RSSHDesktopCore", dependencies: [
            "CRSSHPTY",
            .product(name: "RSSHKit", package: "RSSHKit"),
            .product(name: "RSSHRemote", package: "RSSHRemote"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "RSSHDesktopCoreTests", dependencies: [
            "RSSHDesktopCore",
            .product(name: "RSSHKit", package: "RSSHKit"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
    ]
)
