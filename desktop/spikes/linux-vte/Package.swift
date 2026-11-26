// swift-tools-version: 6.0
// Spike: a GTK4 window with a VTE terminal, from Swift through C interop (no Swift GTK wrapper).
import PackageDescription

let package = Package(
    name: "LinuxVteSpike",
    targets: [
        // gtk4 + vte-2.91-gtk4 as a system library; pkg-config gives the include and link flags.
        .systemLibrary(name: "CGtkVte", pkgConfig: "vte-2.91-gtk4",
                       providers: [.apt(["libgtk-4-dev", "libvte-2.91-gtk4-dev"])]),
        .executableTarget(name: "LinuxVteSpike", dependencies: ["CGtkVte"]),
    ]
)
