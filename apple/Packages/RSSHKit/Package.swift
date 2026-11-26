// swift-tools-version: 6.0
// RSSHKit: rSSH's models, vault crypto and storage contracts. No UIKit/SwiftUI and only swift-crypto (CryptoKit's API,
// which re-exports CryptoKit on Apple platforms), so `swift test` runs on the Mac and on Linux (swift:6.4-noble).
import PackageDescription

let package = Package(
    name: "RSSHKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RSSHKit", targets: ["RSSHKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "RSSHKit", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            // AES-CBC and PBKDF2 for encrypted PEM keys; the same package (and BoringSSL) Citadel already links.
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .testTarget(name: "RSSHKitTests", dependencies: [
            "RSSHKit",
            // Signs with imported keys and checks the signatures in KeyImport tests.
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
    ]
)
