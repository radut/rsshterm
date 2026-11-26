// Ctrl+Shift+J: every open shell (all windows, tabs and panes), then "New session on <server>". Enter jumps there
// (or opens a tab), Shift+Enter opens a server in a split.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit

@MainActor
enum JumpSwitcherDialog {
    static func present(app: AppController, over window: MainWindow) {
        let servers = app.vault?.servers ?? []
        let groups = app.vault?.groups ?? []
        let desktops = app.vault?.remoteDesktops ?? []
        var shells: [PaneID: (MainWindow, TerminalPane)] = [:]
        var open: [OpenShell] = []
        for w in app.windows {
            for pane in w.allPanes {
                shells[pane.id] = (w, pane)
                open.append(OpenShell(id: pane.id, title: pane.title, host: pane.host, directory: pane.directory,
                                      lastUsed: pane.lastFocused))
            }
        }
        let serverByID = Dictionary(servers.map { ($0.id, $0) }) { a, _ in a }
        var results: [JumpSwitcherResult] = []
        PickerDialog(title: "Jump To", placeholder: "Open shell, host, directory or server",
                     hint: "Enter: jump / new tab · Shift+Enter: server in a split · Esc: close", parent: window.window,
                     empty: { _ in "No match." },
                     rows: { query in
                         results = JumpSwitcher.results(query: query, openShells: open, servers: servers, groups: groups,
                                                        remoteDesktops: desktops)
                         return results.map { result in
                             switch result {
                             case .shell(let id):
                                 let pane = shells[id]?.1
                                 let place = [pane?.host, pane?.directory].compactMap { $0 }.joined(separator: " · ")
                                 return PickerRow(title: pane?.title ?? "Terminal", subtitle: place.isEmpty ? "local shell" : place,
                                                  icon: "utilities-terminal-symbolic")
                             case .newSession(let id):
                                 let s = serverByID[id]
                                 return PickerRow(title: "New session on \(s?.name ?? "server")",
                                                  subtitle: s.map { "\($0.username)@\($0.host)" } ?? "",
                                                  icon: "network-server-symbolic")
                             case .openScreen(let id):
                                 let d = desktops.first { $0.id == id }
                                 return PickerRow(title: "Screen: \(d?.name ?? "remote desktop")",
                                                  subtitle: d.map { "\($0.kind.title) · \($0.host)" } ?? "",
                                                  icon: "video-display-symbolic")
                             }
                         }
                     },
                     pick: { index, split in
                         switch results[index] {
                         case .shell(let id):
                             guard let (w, _) = shells[id] else { return }
                             w.jump(to: id)
                         case .newSession(let id):
                             window.openServer(id, split: split)
                         case .openScreen(let id):
                             window.openRemoteDesktop(id, split: split)
                         }
                     }).present()
    }
}
