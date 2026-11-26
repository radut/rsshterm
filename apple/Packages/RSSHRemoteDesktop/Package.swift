// swift-tools-version: 6.0
// RSSHRemoteDesktop: remote desktops (VNC, Apple Screen Sharing, later RDP) over an SSH tunnel, shared by the iOS
// app and the desktop apps. No UIKit/AppKit/SwiftUI, so `swift test` runs on Linux (swift:6.4-noble) and the Mac.
//
//   RSSHTunnel  a local port forward over an SSH connection (direct-tcpip), as a 127.0.0.1 listener
//   RSSHVNC     RFB probe (version + security types) and a VNC session on RoyalVNCKit (MIT)
import PackageDescription

let package = Package(
    name: "RSSHRemoteDesktop",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RSSHTunnel", targets: ["RSSHTunnel"]),
        .library(name: "RSSHVNC", targets: ["RSSHVNC"]),
        // What a VNC server / Mac offers (version, security types), no credentials: `swift run rssh-rfb-probe`.
        .executable(name: "rssh-rfb-probe", targets: ["rssh-rfb-probe"]),
    ],
    dependencies: [
        .package(path: "../RSSHKit"),
        .package(path: "../Vendor/Citadel"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
        // Vendored (MIT) with one patch, clipboard on request: ../Vendor/RoyalVNCKit/PATCHES.md.
        .package(path: "../Vendor/RoyalVNCKit"),
    ],
    targets: [
        .target(name: "RSSHTunnel", dependencies: [
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .target(name: "RSSHVNC", dependencies: [
            "RSSHTunnel",
            .product(name: "RSSHKit", package: "RSSHKit"),
            .product(name: "RoyalVNCKit", package: "RoyalVNCKit"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .executableTarget(name: "rssh-rfb-probe", dependencies: ["RSSHVNC"]),
        .testTarget(name: "RSSHTunnelTests", dependencies: [
            "RSSHTunnel",
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .testTarget(name: "RSSHVNCTests", dependencies: [
            "RSSHVNC", "RSSHTunnel",
            .product(name: "RSSHKit", package: "RSSHKit"),
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "RoyalVNCKit", package: "RoyalVNCKit"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
    ]
)
