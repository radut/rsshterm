// rsshterm: the Linux app. `rsshterm` opens a window; `rsshterm --version`; `rsshterm vault import <file.json>`
// creates this device's vault from a plaintext vault document (master password from RSSH_MASTER_PASSWORD or asked).
import CGtk
import Foundation
import RSSHKit
import RSSHTermLinux

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

if arguments.first == "--version" {
    print("rsshterm \(RSSHTermVersion.current)")
    exit(0)
}

if arguments.count == 3, arguments[0] == "vault", arguments[1] == "import" {
    exit(VaultImport.run(file: arguments[2], environment: environment))
}

if let unknown = arguments.first {
    fputs("usage: rsshterm [--version | vault import <vault.json>]\nunknown argument: \(unknown)\n", stderr)
    exit(2)
}

nonisolated(unsafe) var controller: AppController?
let status: Int32 = MainActor.assumeIsolated {
    // The X11 WM_CLASS / Wayland app id: inside an AppImage the binary is started as "AppRun.wrapped", so docks
    // would not match the window to dev.rsshterm.RSSHTerm.desktop (StartupWMClass) without this.
    g_set_prgname("dev.rsshterm.RSSHTerm")
    let gtkApp = adw_application_new("dev.rsshterm.RSSHTerm", G_APPLICATION_DEFAULT_FLAGS)!
    controller = AppController(gtkApp: OpaquePointer(gtkApp), environment: environment)
    on(gtkApp, "activate") { controller?.activate() }
    let status = g_application_run(cast(gtkApp), 1, CommandLine.unsafeArgv)
    controller = nil
    g_object_unref(gtkApp.gptr)
    return status
}
exit(status)
