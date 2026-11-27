// rsshterm: the Linux app. `rsshterm` opens a window with a local shell; `rsshterm -e cmd args`, `--working-directory
// DIR`, `-T title`, `ssh://user@host` (a default terminal's command line); `rsshterm --version`; `rsshterm vault import <file.json>`
// creates this device's vault from a plaintext vault document (master password from RSSH_MASTER_PASSWORD or asked).
import CGtk
import Foundation
import RSSHDesktopCore
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

// A default terminal's command line (x-terminal-emulator, xdg-terminal-exec, Nautilus): checked here so a mistake is
// reported in the caller's terminal; the running instance (or this one) then opens it (AppController.commandLine).
do { _ = try TerminalArguments.parse(arguments) } catch {
    fputs("usage: rsshterm [-e command [args…]] [--working-directory DIR] [-T title] [ssh://user@host:port]\n"
        + "       rsshterm --version | vault import <vault.json>\n\(error.localizedDescription)\n", stderr)
    exit(2)
}

nonisolated(unsafe) var controller: AppController?
let status: Int32 = MainActor.assumeIsolated {
    // The X11 WM_CLASS / Wayland app id: inside an AppImage the binary is started as "AppRun.wrapped", so docks
    // would not match the window to dev.rsshterm.RSSHTerm.desktop (StartupWMClass) without this.
    g_set_prgname("dev.rsshterm.RSSHTerm")
    // One instance: a second `rsshterm -e …` hands its command line and folder to the first, which opens a tab.
    let gtkApp = adw_application_new("dev.rsshterm.RSSHTerm", G_APPLICATION_HANDLES_COMMAND_LINE)!
    controller = AppController(gtkApp: OpaquePointer(gtkApp), environment: environment)
    on(gtkApp, "activate") { controller?.activate() }
    let onCommandLine: @convention(c) (gpointer?, gpointer?, gpointer?) -> Int32 = { _, raw, _ in
        MainActor.assumeIsolated {
            let cmdline = raw?.assumingMemoryBound(to: GApplicationCommandLine.self)
            var argc: Int32 = 0
            guard let argv = g_application_command_line_get_arguments(cmdline, &argc) else { return 1 }
            defer { g_strfreev(argv) }
            let words = (1..<max(1, Int(argc))).compactMap { argv[$0].map { String(cString: $0) } }
            let cwd = g_application_command_line_get_cwd(cmdline).map { String(cString: $0) }
            return controller?.commandLine(words, directory: cwd) ?? 1
        }
    }
    g_signal_connect_data(gtkApp, "command-line", unsafeBitCast(onCommandLine, to: GCallback.self), nil, nil,
                          GConnectFlags(rawValue: 0))
    let status = g_application_run(cast(gtkApp), CommandLine.argc, CommandLine.unsafeArgv)
    controller = nil
    g_object_unref(gtkApp.gptr)
    return status
}
exit(status)
