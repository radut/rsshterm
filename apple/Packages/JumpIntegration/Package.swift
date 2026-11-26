// swift-tools-version: 6.0
// Jump host integration: the app's JumpChainConnector (Sources/JumpIntegration/JumpChainConnector.swift is a link to
// apple/RSSH/App/Session/JumpChainConnector.swift) against two real OpenSSH servers in docker, on Linux.
// Run with `make test-jump-linux` (docker/run.sh); without RSSH_JUMP_IT_HOST the tests are skipped.
import PackageDescription

let package = Package(
    name: "JumpIntegration",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        .package(path: "../Vendor/Citadel"),
        .package(path: "../Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    ],
    targets: [
        .target(name: "JumpIntegration", dependencies: [
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
        ]),
        .testTarget(name: "JumpIntegrationTests", dependencies: [
            "JumpIntegration",
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
        ]),
    ]
)
