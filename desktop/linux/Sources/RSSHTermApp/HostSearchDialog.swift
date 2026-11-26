// Ctrl+Shift+K: fuzzy search over the vault's servers, then its remote desktops (core RemoteDesktopSearch).
// Enter opens a tab, Shift+Enter a split.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHKit
import RSSHTermLinux

@MainActor
enum HostSearchDialog {
    static func present(servers: [Server], groups: [ServerGroup], desktops: [RemoteDesktop], over window: MainWindow) {
        var model = HostSearchModel(servers: servers, groups: groups)
        var screens: [RemoteDesktop] = []
        PickerDialog(title: "Search Hosts", placeholder: "Server, screen, host, user or group",
                     hint: "Enter: new tab · Shift+Enter: split · Esc: close", parent: window.window,
                     empty: { $0.isEmpty ? "The vault has no servers yet." : "No match." },
                     rows: { query in
                         model = model.searching(query)
                         screens = RemoteDesktopSearch.search(query, desktops: desktops, groups: groups, servers: servers)
                         return model.results.map { r in
                             PickerRow(title: r.server.name,
                                       subtitle: HostSearchModel.subtitle(r) + (r.groupName.map { " · \($0)" } ?? ""),
                                       icon: "network-server-symbolic")
                         } + screens.map { d in
                             PickerRow(title: d.name, subtitle: SidebarRows.subtitle(d, servers: servers),
                                       icon: "video-display-symbolic")
                         }
                     },
                     pick: { index, split in
                         if index < model.results.count {
                             window.openServer(model.results[index].server.id, split: split)
                         } else {
                             window.openRemoteDesktop(screens[index - model.results.count].id, split: split)
                         }
                     }).present()
    }
}
