// swift-tools-version: 6.0
// RSSHRemote: rSSH's SSH-side code that needs Citadel but no UI: SFTP as a `FileSource`, vault credentials as Citadel
// login methods, host-key pinning during the handshake, and a connector that opens SFTP (through jump hosts) for the
// desktop. The iOS app and both desktop apps link it, so there is one SFTP implementation. `swift test` runs on Linux
// (swift:6.4-noble) and on the Mac.
import PackageDescription

let package = Package(
    name: "RSSHRemote",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RSSHRemote", targets: ["RSSHRemote"]),
    ],
    dependencies: [
        .package(path: "../RSSHKit"),
        .package(path: "../Vendor/Citadel"),
        .package(path: "../Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "RSSHRemote", dependencies: [
            .product(name: "RSSHKit", package: "RSSHKit"),
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "RSSHRemoteTests", dependencies: [
            "RSSHRemote",
            .product(name: "RSSHKit", package: "RSSHKit"),
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ]
)
