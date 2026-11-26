// swift-tools-version: 6.0
// rSshTerm for Linux: GTK4 + libadwaita + VTE through C interop (no Swift GTK wrapper), on RSSHDesktopCore (layout,
// keys, host search, agent, ssh_config, updater) and RSSHKit (vault, stores, key stores).
//
//   RSSHTermLinux   the app's logic without GTK (key translation, unlock flow, spawn plans, settings, ...): unit tests
//   RSSHTermApp     the GTK/libadwaita/VTE UI, product `rsshterm`
//   CGtk            gtk4 + libadwaita-1 + vte-2.91-gtk4 headers and the macros Swift cannot import
//
// Build deps (Ubuntu 24.04): libgtk-4-dev libadwaita-1-dev libvte-2.91-gtk4-dev pkg-config zlib1g-dev (RoyalVNCKit) freerdp3-dev (RDP).
import PackageDescription

let package = Package(
    name: "RSSHTermLinux",
    products: [
        .executable(name: "rsshterm", targets: ["RSSHTermApp"]),
    ],
    dependencies: [
        .package(path: "../Packages/RSSHDesktopCore"),
        .package(path: "../../apple/Packages/RSSHKit"),
        .package(path: "../../apple/Packages/RSSHRemoteDesktop"),
        .package(path: "../../apple/Packages/RSSHRDP"),
    ],
    targets: [
        // vte-2.91-gtk4's pkg-config pulls in gtk4; libadwaita's headers are found through <libadwaita-1/...>.
        .systemLibrary(name: "CGtk", pkgConfig: "vte-2.91-gtk4",
                       providers: [.apt(["libgtk-4-dev", "libadwaita-1-dev", "libvte-2.91-gtk4-dev"])]),
        .target(name: "RSSHTermLinux", dependencies: [
            .product(name: "RSSHDesktopCore", package: "RSSHDesktopCore"),
            .product(name: "RSSHKit", package: "RSSHKit"),
        ]),
        .executableTarget(name: "RSSHTermApp", dependencies: [
            "CGtk", "RSSHTermLinux",
            .product(name: "RSSHTunnel", package: "RSSHRemoteDesktop"),
            .product(name: "RSSHVNC", package: "RSSHRemoteDesktop"),
            .product(name: "RSSHRDP", package: "RSSHRDP"),
            .product(name: "RSSHDesktopCore", package: "RSSHDesktopCore"),
            .product(name: "RSSHKit", package: "RSSHKit"),
        ], swiftSettings: [
            // GTK callbacks are C function pointers on the main loop; Swift 6 isolation checking cannot see that.
            .swiftLanguageMode(.v5),
        ]),
        .testTarget(name: "RSSHTermLinuxTests", dependencies: [
            "RSSHTermLinux",
            .product(name: "RSSHDesktopCore", package: "RSSHDesktopCore"),
            .product(name: "RSSHKit", package: "RSSHKit"),
        ]),
    ]
)
