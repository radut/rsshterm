// swift-tools-version: 6.0
// RSSHRDP: RDP screens over FreeRDP 3 (Apache-2.0), for the desktop apps and iOS.
//
//   CFreeRDP / FreeRDP   the library: on Linux the system's libfreerdp3 (pkg-config freerdp3 freerdp-client3 winpr3,
//                        Ubuntu freerdp3-dev); on Apple FreeRDP.xcframework (FreeRDP + OpenSSL, static), built by
//                        apple/scripts/freerdp/build-xcframework.sh into Frameworks/ (not committed;
//                        apple/scripts/freerdp/fetch.sh puts the cached build there)
//   CRSSHRDP             a small C layer: connect, software GDI frames, queued input, certificate callback, text clipboard
//   RSSHRDP              RDPSession: the same events as VNCSession, certificate pinning from the vault entry
import Foundation
import PackageDescription

// The manifest is compiled on the build host: a Mac builds for Apple platforms (xcframework), Linux for itself.
#if os(macOS)
let freeRDP: Target = .binaryTarget(name: "FreeRDP", path: "Frameworks/FreeRDP.xcframework")
let freeRDPDependency: Target.Dependency = "FreeRDP"
// What the static FreeRDP and OpenSSL need from the system.
let freeRDPLinker: [LinkerSetting] = [
    .linkedFramework("CoreFoundation"), .linkedFramework("Security"), .linkedFramework("SystemConfiguration"),
    .linkedLibrary("z"), .linkedLibrary("iconv"),
]
#else
let freeRDP: Target = .systemLibrary(name: "CFreeRDP", pkgConfig: "freerdp3 freerdp-client3 winpr3",
                                     providers: [.apt(["freerdp3-dev"])])
let freeRDPDependency: Target.Dependency = "CFreeRDP"
let freeRDPLinker: [LinkerSetting] = []
#endif

let package = Package(
    name: "RSSHRDP",
    platforms: [.iOS(.v18), .macOS(.v15)],
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
        freeRDP,
        .target(name: "CRSSHRDP", dependencies: [freeRDPDependency], linkerSettings: freeRDPLinker),
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
