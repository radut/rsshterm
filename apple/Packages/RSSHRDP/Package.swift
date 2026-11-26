// swift-tools-version: 6.0
// RSSHRDP: RDP screens on Linux through the system's libfreerdp3 (Apache-2.0; Ubuntu freerdp3-dev), for the
// desktop app. Its own package so RSSHRemoteDesktop stays buildable for iOS and the Mac, where FreeRDP is not
// installed (macOS: an xcframework from the pipeline later; iOS: later still, docs/research/remote-desktop.md).
//
//   CFreeRDP   the system library (pkg-config freerdp3 freerdp-client3 winpr3)
//   CRSSHRDP   a small C layer: connect, software GDI frames, queued input, certificate callback, text clipboard
//   RSSHRDP    RDPSession: the same events as VNCSession, certificate pinning from the vault entry
import PackageDescription

let package = Package(
    name: "RSSHRDP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RSSHRDP", targets: ["RSSHRDP"]),
    ],
    dependencies: [
        .package(path: "../RSSHKit"),
        .package(path: "../RSSHRemoteDesktop"),
        .package(path: "../Vendor/Citadel"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .systemLibrary(name: "CFreeRDP", pkgConfig: "freerdp3 freerdp-client3 winpr3",
                       providers: [.apt(["freerdp3-dev"])]),
        .target(name: "CRSSHRDP", dependencies: ["CFreeRDP"]),
        .target(name: "RSSHRDP", dependencies: [
            "CRSSHRDP",
            .product(name: "RSSHKit", package: "RSSHKit"),
            .product(name: "RSSHVNC", package: "RSSHRemoteDesktop"),
        ]),
        .testTarget(name: "RSSHRDPTests", dependencies: [
            "RSSHRDP",
            .product(name: "RSSHKit", package: "RSSHKit"),
            .product(name: "RSSHTunnel", package: "RSSHRemoteDesktop"),
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ]
)
