// F4 opens a downloaded copy of a remote file. The server chooses its name, so the file must never be opened by
// its type (xdg-open would run a .desktop entry or hand a script to whatever runs it): it goes to the desktop's
// default *text editor* (the text/plain handler) or, without one, to $VISUAL / $EDITOR in a new terminal tab.
import CGtk
import Foundation

@MainActor
enum TextEditorLauncher {
    static func open(_ url: URL, app: AppController) {
        if let info = g_app_info_get_default_for_type("text/plain", 0) {
            defer { g_object_unref(info.gptr) }
            let file = g_file_new_for_path(url.path)
            defer { g_object_unref(file.gptr) }
            let files = g_list_append(nil, file.gptr)
            defer { g_list_free(files) }
            var error: UnsafeMutablePointer<GError>?
            if g_app_info_launch(info, files, nil, &error) != 0 { return }
            if let error { g_error_free(error) }
        }
        let env = ProcessInfo.processInfo.environment
        if let editor = (env["VISUAL"] ?? env["EDITOR"]).flatMap({ $0.isEmpty ? nil : $0 }), let window = app.activeWindow {
            // The editor command as the user set it (may carry flags), the file as one argument.
            window.openCommand(["/bin/sh", "-c", "exec \(editor) \"$1\"", "rsshterm-edit", url.path], title: url.lastPathComponent)
            return
        }
        app.activeWindow?.toast("No text editor found: set one for text files, or $EDITOR.")
    }
}
