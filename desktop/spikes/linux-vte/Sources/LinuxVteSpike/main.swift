// A GTK4 window holding one VTE terminal that runs $SHELL; `--smoke` runs a short child instead, reads its output
// back from the terminal screen and exits with a status the smoke test checks.
import CGtkVte
import Foundation

let smoke = CommandLine.arguments.contains("--smoke")
let marker = "rssh-spike-marker"

nonisolated(unsafe) var terminal: UnsafeMutablePointer<VteTerminal>?
nonisolated(unsafe) var app: UnsafeMutablePointer<GtkApplication>?
nonisolated(unsafe) var exitCode: Int32 = 0

/// argv for the child: the smoke child prints the marker in two pieces so the command line itself never matches.
func childArgv() -> [UnsafeMutablePointer<CChar>?] {
    let words: [String]
    if smoke {
        words = ["/bin/sh", "-c", "printf '%s-%s\\n' rssh-spike marker; exit 0"]
    } else {
        words = [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"]
    }
    return words.map { strdup($0) } + [nil]
}

let onChildExited: @convention(c) (UnsafeMutablePointer<VteTerminal>?, Int32, gpointer?) -> Void = { term, status, _ in
    guard smoke else { g_application_quit(spike_app(app)); return }
    var screen = ""
    if let term, let text = vte_terminal_get_text_format(term, VTE_FORMAT_TEXT) {
        screen = String(cString: text)
        g_free(text)
    }
    let hasMarker = screen.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == marker }
    print("screen-has-marker: \(hasMarker ? "yes" : "no")")
    print("child-exit-status: \(status)")
    exitCode = (hasMarker && status == 0) ? 0 : 1
    g_application_quit(spike_app(app))
}

let onSpawned: VteTerminalSpawnAsyncCallback = { _, pid, error, _ in
    if let error {
        print("spawn-error: \(String(cString: error.pointee.message))")
        exitCode = 3
        g_application_quit(spike_app(app))
    } else {
        print("spawned-pid: \(pid)")
    }
}

let onTimeout: @convention(c) (gpointer?) -> gboolean = { _ in
    print("timeout: child did not exit")
    exitCode = 2
    g_application_quit(spike_app(app))
    return 0 // G_SOURCE_REMOVE
}

let onActivate: @convention(c) (UnsafeMutablePointer<GtkApplication>?, gpointer?) -> Void = { application, _ in
    let window = gtk_application_window_new(application)
    gtk_window_set_title(spike_window(window), "rSshTerm spike: GTK4 + VTE")
    gtk_window_set_default_size(spike_window(window), 800, 500)

    let termWidget = vte_terminal_new()
    guard let term = spike_terminal(termWidget) else { fatalError("vte_terminal_new returned no terminal") }
    terminal = term
    vte_terminal_set_scrollback_lines(term, 10_000)
    gtk_window_set_child(spike_window(window), termWidget)
    spike_connect(UnsafeMutableRawPointer(term), "child-exited", unsafeBitCast(onChildExited, to: GCallback.self), nil)

    var argv = childArgv()
    argv.withUnsafeMutableBufferPointer { buf in
        vte_terminal_spawn_async(term, VTE_PTY_DEFAULT, nil, buf.baseAddress!, nil, G_SPAWN_DEFAULT,
                                 nil, nil, nil, -1, nil, onSpawned, nil)
    }
    argv.forEach { free($0) }
    if smoke { g_timeout_add_seconds(10, onTimeout, nil) }
    gtk_window_present(spike_window(window))
}

app = gtk_application_new("dev.rsshterm.spike.LinuxVte", G_APPLICATION_NON_UNIQUE)
spike_connect(UnsafeMutableRawPointer(app), "activate", unsafeBitCast(onActivate, to: GCallback.self), nil)
// Pass only argv[0]: GApplication would reject our own `--smoke` flag.
let status = g_application_run(spike_app(app), 1, CommandLine.unsafeArgv)
g_object_unref(UnsafeMutableRawPointer(app))
exit(status != 0 ? status : exitCode)
