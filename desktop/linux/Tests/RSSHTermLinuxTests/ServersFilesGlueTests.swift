import Foundation
import RSSHDesktopCore
import RSSHKit
import Testing
@testable import RSSHTermLinux

@Suite struct SidebarRowsTests {
    let web = Server(name: "Web Prod 1", host: "web1.example.com", username: "deploy")
    let db = Server(name: "db", host: "db.example.com", username: "pg")
    let nas = Server(name: "Backup NAS", host: "nas.example.org", username: "admin")

    @Test func headersThenServersAndCollapsedHidesRows() {
        let prod = UUID()
        let sections = [
            ServerListModel.Section(groupID: nil, title: "Servers", servers: [nas], isCollapsed: false),
            ServerListModel.Section(groupID: prod, title: "Production", servers: [web, db], isCollapsed: true),
        ]
        let rows = SidebarRows.flatten(sections)
        #expect(rows == [
            .header(groupID: nil, title: "Servers", count: 1, collapsed: false),
            .server(nas, groupID: nil),
            .header(groupID: prod, title: "Production", count: 2, collapsed: true),
        ])
    }

    @Test func subtitleShowsUserHostPortAndTags() {
        var s = Server(name: "x", host: "h.example.com", port: 2222, username: "ci")
        s.tags = ["ci", "linux"]
        #expect(SidebarRows.subtitle(s) == "ci@h.example.com:2222 · #ci #linux")
        #expect(SidebarRows.subtitle(web) == "deploy@web1.example.com")
    }
}

@Suite struct FileRowTextTests {
    @Test func sizes() {
        #expect(FileRowText.size(nil, isDirectory: true) == "—")
        #expect(FileRowText.size(0, isDirectory: false) == "0 B")
        #expect(FileRowText.size(1023, isDirectory: false) == "1023 B")
        #expect(FileRowText.size(1536, isDirectory: false) == "1.5 KB")
        #expect(FileRowText.size(5 * 1024 * 1024, isDirectory: false) == "5.0 MB")
        #expect(FileRowText.size(3 * 1024 * 1024 * 1024, isDirectory: false) == "3.0 GB")
    }

    @Test func permissions() {
        #expect(FileRowText.mode(0o755, isDirectory: true) == "drwxr-xr-x")
        #expect(FileRowText.mode(0o640, isDirectory: false) == "-rw-r-----")
        #expect(FileRowText.mode(nil, isDirectory: false) == "")
    }

    @Test func dates() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(FileRowText.date(Date(timeIntervalSince1970: 1_800_000_000), timeZone: utc) == "2027-01-15 08:00")
        #expect(FileRowText.date(nil, timeZone: utc) == "")
    }
}

@Suite struct OpenHereTests {
    let server = UUID()

    @Test func localShellOpensThisComputerAtItsDirectory() {
        let dir = ShellDirectory(host: "workstation", path: FilePath("/home/you/src"))
        let t = OpenHere.target(content: .localShell(), directory: dir, home: "/home/you", localHostName: "workstation")
        #expect(t?.place == .local)
        #expect(t?.path == FilePath("/home/you/src"))
    }

    @Test func localShellWithoutOSC7OpensHome() {
        let t = OpenHere.target(content: .localShell(), directory: nil, home: "/home/you", localHostName: "workstation")
        #expect(t?.place == .local)
        #expect(t?.path == FilePath("/home/you"))
    }

    @Test func sshPaneOpensTheServerAtTheRemoteDirectory() {
        let remote = ShellDirectory(host: "web1", path: FilePath("/var/www"))
        let t = OpenHere.target(content: .ssh(serverID: server), directory: remote, home: "/home/you", localHostName: "workstation")
        #expect(t?.place == .server(server))
        #expect(t?.path == FilePath("/var/www"))
        // the local ssh process's own directory is not the server's
        let local = ShellDirectory(host: "workstation", path: FilePath("/home/you"))
        let u = OpenHere.target(content: .ssh(serverID: server), directory: local, home: "/home/you", localHostName: "workstation")
        #expect(u?.place == .server(server))
        #expect(u?.path == nil)
    }
}

@Suite struct TerminalAppearanceTests {
    @Test func serverOverridesFontAndTheme() {
        var s = Server(name: "x", host: "h.example.com", username: "u")
        s.fontFamily = "JetBrains Mono"
        s.fontSize = 14
        s.themeID = TerminalColorSchemes.defaultLight.id
        let a = TerminalAppearance.resolve(defaultFont: "Monospace 11", server: s)
        #expect(a.font == "JetBrains Mono 14")
        #expect(a.scheme?.id == TerminalColorSchemes.defaultLight.id)
    }

    @Test func partialOverrides() {
        var s = Server(name: "x", host: "h.example.com", username: "u")
        s.fontSize = 16
        #expect(TerminalAppearance.resolve(defaultFont: "DejaVu Sans Mono 11", server: s).font == "DejaVu Sans Mono 16")
        s.fontSize = nil
        s.fontFamily = "Hack"
        #expect(TerminalAppearance.resolve(defaultFont: "DejaVu Sans Mono 11", server: s).font == "Hack 11")
        #expect(TerminalAppearance.resolve(defaultFont: "Monospace 11", server: nil).font == "Monospace 11")
        #expect(TerminalAppearance.resolve(defaultFont: "Monospace 11", server: nil).scheme == nil)
    }
}

@Suite struct QuickConnectCommandTests {
    @Test func sshArgv() {
        let plan = QuickConnectPlan(target: ConnectionTarget(host: "web1.example.com", port: 22, username: "deploy"), logins: [])
        #expect(QuickConnectCommand.argv(plan) == ["ssh", "deploy@web1.example.com"])
        let p2 = QuickConnectPlan(target: ConnectionTarget(host: "10.0.0.5", port: 2222, username: "ci"), logins: [])
        #expect(QuickConnectCommand.argv(p2) == ["ssh", "-p", "2222", "ci@10.0.0.5"])
        #expect(QuickConnectCommand.argv(p2, via: "you@bastion.example.com") == ["ssh", "-J", "you@bastion.example.com", "-p", "2222", "ci@10.0.0.5"])
    }
}

@Suite struct PaneDragTokenTests {
    @Test func roundTrip() {
        let paths = [FilePath("/var/www/index.html"), FilePath("/var/www/a b.txt")]
        let token = PaneDragToken.encode(side: .right, paths: paths)
        let decoded = PaneDragToken.decode(token)
        #expect(decoded?.side == .right)
        #expect(decoded?.paths == paths)
    }

    @Test func foreignTextIsNotAToken() {
        #expect(PaneDragToken.decode("hello") == nil)
        #expect(PaneDragToken.decode("") == nil)
        #expect(PaneDragToken.decode("rsshterm-pane:middle\n/x") == nil)
        #expect(PaneDragToken.decode("rsshterm-pane:left\n") == nil)
    }

    @Test func uriListForLocalFiles() {
        #expect(PaneDragToken.uriList([FilePath("/home/you/a b.txt")]) == "file:///home/you/a%20b.txt\r\n")
    }
}
