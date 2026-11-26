import Foundation
import RSSHDesktopCore
import RSSHKit
import Testing
@testable import RSSHTermLinux

@Suite struct ScreenGeometryTests {
    @Test func fitKeepsTheAspectAndCenters() {
        let g = ScreenGeometry(remoteWidth: 1280, remoteHeight: 800, viewWidth: 640, viewHeight: 800, mode: .fit)
        #expect(g.scale == 0.5)
        #expect(g.offsetX == 0)
        #expect(g.offsetY == 200) // (800 - 400) / 2
        #expect(g.toRemote(x: 320, y: 400).map { [$0.0, $0.1] } == [640, 400])
        #expect(g.toRemote(x: 0, y: 0) == nil) // above the picture
    }

    @Test func fitNeverEnlarges() {
        let g = ScreenGeometry(remoteWidth: 640, remoteHeight: 400, viewWidth: 1280, viewHeight: 800, mode: .fit)
        #expect(g.scale == 1)
        #expect(g.offsetX == 320)
    }

    @Test func actualSizeIsOneToOneFromTheCorner() {
        let g = ScreenGeometry(remoteWidth: 1920, remoteHeight: 1080, viewWidth: 800, viewHeight: 600, mode: .actualSize)
        #expect(g.scale == 1)
        #expect(g.offsetX == 0 && g.offsetY == 0)
        #expect(g.toRemote(x: 799, y: 599).map { [$0.0, $0.1] } == [799, 599])
    }
}

@Suite struct KeyGrabTests {
    @Test func ctrlAltReleases() {
        #expect(KeyGrab.isReleaseChord(keyval: 0xffe9, state: 1 << 2)) // Alt_L with Ctrl held
        #expect(KeyGrab.isReleaseChord(keyval: 0xffe3, state: 1 << 3)) // Control_L with Alt held
        #expect(!KeyGrab.isReleaseChord(keyval: 0x61, state: (1 << 2) | (1 << 3))) // Ctrl+Alt+a goes to the screen
        #expect(!KeyGrab.isReleaseChord(keyval: 0xffe3, state: 0))
    }

    @Test func modifierKeysym() {
        // GDK keyvals are X11 keysyms: passed through as they are.
        #expect(KeyGrab.keysym(for: 0xff0d) == X11KeysymReturn)
        #expect(KeyGrab.keysym(for: 0x41) == 0x41)
    }
}

let X11KeysymReturn: UInt32 = 0xff0d

@Suite struct RemoteDesktopFormTests {
    let gateway = Server(name: "Web Prod 1", host: "web1.example.com", username: "deploy")

    @Test func newEntryDefaultsAndPortFollowsKind() {
        var form = RemoteDesktopForm(desktop: nil, servers: [gateway])
        #expect(form.kind == .vnc)
        #expect(form.port == "5900")
        form.setKind(.rdp)
        #expect(form.port == "3389")
        form.port = "3390"
        form.setKind(.vnc) // a port the user typed stays
        #expect(form.port == "3390")
    }

    @Test func validation() {
        var form = RemoteDesktopForm(desktop: nil, servers: [gateway])
        form.name = "Lab VNC"
        form.host = ""
        #expect(form.issues.contains(.host))
        form.host = "localhost"
        form.port = "99999"
        #expect(form.issues.contains(.port))
        form.port = "5901"
        form.transport = .sshShared
        form.tunnelServerID = nil
        #expect(form.issues.contains(.tunnelServer))
        form.tunnelServerID = gateway.id
        #expect(form.issues.isEmpty)
        let d = try! form.makeDesktop(id: UUID())
        #expect(d.host == "localhost" && d.port == 5901 && d.tunnelServerID == gateway.id && d.transport == .sshShared)
        #expect(d.name == "Lab VNC")
    }

    @Test func directNeedsNoServerAndWarns() {
        var form = RemoteDesktopForm(desktop: nil, servers: [gateway])
        form.host = "vnc.example.org"
        form.transport = .direct
        #expect(form.issues.isEmpty)
        #expect(form.directWarning?.contains("not encrypted") == true)
        form.setKind(.rdp)
        #expect(form.directWarning?.contains("exposed") == true)
        form.transport = .sshSeparate
        form.tunnelServerID = gateway.id
        #expect(form.directWarning == nil)
    }

    @Test func roundTripKeepsEveryField() throws {
        let original = RemoteDesktop(name: "Mac mini", kind: .appleScreenSharing, host: "localhost", username: "me",
                                     credentialID: UUID(), groupID: UUID(), tunnelServerID: gateway.id,
                                     shareClipboard: true, transport: .sshSeparate, askEveryTime: true)
        let form = RemoteDesktopForm(desktop: original, servers: [gateway])
        #expect(try form.makeDesktop(id: original.id) == original)
    }

    @Test func nameDefaultsToHost() throws {
        var form = RemoteDesktopForm(desktop: nil, servers: [gateway])
        form.host = "vnc.example.org"
        form.transport = .direct
        #expect(try form.makeDesktop(id: UUID()).name == "vnc.example.org")
    }
}

@Suite struct SidebarDesktopRowsTests {
    @Test func desktopsFollowTheServersOfTheirFolder() {
        let prod = UUID()
        let web = Server(name: "Web Prod 1", host: "web1.example.com", username: "deploy", groupID: prod)
        let lab = RemoteDesktop(name: "Lab VNC", kind: .vnc, host: "localhost", groupID: prod, tunnelServerID: web.id)
        let loose = RemoteDesktop(name: "Kiosk", kind: .vnc, host: "kiosk.example.org")
        let sections = [
            ServerListModel.Section(groupID: nil, title: "Servers", servers: [], isCollapsed: false),
            ServerListModel.Section(groupID: prod, title: "Production", servers: [web], isCollapsed: false),
        ]
        let rows = SidebarRows.flatten(sections, desktops: [lab, loose], query: "")
        #expect(rows == [
            .header(groupID: nil, title: "Servers", count: 1, collapsed: false),
            .desktop(loose, groupID: nil),
            .header(groupID: prod, title: "Production", count: 2, collapsed: false),
            .server(web, groupID: prod),
            .desktop(lab, groupID: prod),
        ])
        // the search filters screens by name and host too
        #expect(SidebarRows.flatten(sections, desktops: [lab, loose], query: "kiosk").contains(.desktop(loose, groupID: nil)))
        #expect(!SidebarRows.flatten(sections, desktops: [lab, loose], query: "kiosk").contains(.desktop(lab, groupID: prod)))
    }

    @Test func aServersOwnScreensAreNotRowsOfTheirOwn() {
        let web = Server(name: "Web", host: "web1.example.com", username: "deploy")
        let own = RemoteDesktop(name: "Web", kind: .rdp, host: "localhost", tunnelServerID: web.id, serverID: web.id)
        let sections = [ServerListModel.Section(groupID: nil, title: "Servers", servers: [web], isCollapsed: false)]
        #expect(SidebarRows.flatten(sections, desktops: [own], query: "") == [
            .header(groupID: nil, title: "Servers", count: 1, collapsed: false), .server(web, groupID: nil),
        ])
    }

    @Test func serverSubtitleNamesItsScreens() {
        var web = Server(name: "Web", host: "web1.example.com", username: "deploy")
        #expect(SidebarRows.subtitle(web, screens: [.rdp, .vnc]) == "deploy@web1.example.com · RDP · VNC")
        web.sshEnabled = false
        #expect(SidebarRows.subtitle(web, screens: [.rdp]) == "RDP · web1.example.com")
    }

    @Test func subtitleSaysKindAndRoute() {
        let web = Server(name: "Web Prod 1", host: "web1.example.com", username: "deploy")
        let lab = RemoteDesktop(name: "Lab VNC", kind: .vnc, host: "localhost", port: 5901, tunnelServerID: web.id)
        #expect(SidebarRows.subtitle(lab, servers: [web]) == "VNC · localhost:5901 via Web Prod 1")
        let direct = RemoteDesktop(name: "Kiosk", kind: .vnc, host: "kiosk.example.org")
        #expect(SidebarRows.subtitle(direct, servers: [web]) == "VNC · kiosk.example.org · direct, not encrypted")
    }
}

@Suite struct ScreenCardTests {
    @Test func tunnelErrorsOfferTheTerminal() {
        let card = ScreenCard.failed("connect to localhost:5901 refused", tunnelServer: "Web Prod 1")
        #expect(card.title == "Could not open the screen")
        #expect(card.message == "Web Prod 1: connect to localhost:5901 refused")
        #expect(card.actions == [.retry, .edit, .openTerminal])
        let direct = ScreenCard.failed("timed out", tunnelServer: nil)
        #expect(direct.actions == [.retry, .edit])
    }

    @Test func progressAndClosed() {
        #expect(ScreenCard.progress("Opening screen…").actions.isEmpty)
        #expect(ScreenCard.disconnected(nil).actions == [.retry])
        #expect(ScreenCard.disconnected(nil).message == "The screen was closed.")
    }
}

@Suite struct RDPGlueTests {
    @Test func changedCertificateIsARefusalWithTrustNew() {
        let card = ScreenCard.certificateChanged(expected: "aa11", presented: "bb22")
        #expect(card.title == "The certificate changed")
        #expect(card.message.contains("aa11") && card.message.contains("bb22"))
        #expect(card.actions == [.trustNew, .edit])
        #expect(!card.busy)
    }

    @Test func requestedDesktopSizeFollowsThePaneWithinLimits() {
        #expect(RDPDesktopSize.requested(viewWidth: 1201, viewHeight: 701) == (1200, 700))
        #expect(RDPDesktopSize.requested(viewWidth: 200, viewHeight: 100) == (800, 600))
        #expect(RDPDesktopSize.requested(viewWidth: 9000, viewHeight: 5000) == (3840, 2160))
    }

    @Test func tabReorderTarget() {
        #expect(TabReorder.destination(from: 0, onto: 2, count: 4) == 2)
        #expect(TabReorder.destination(from: 3, onto: 1, count: 4) == 1)
        #expect(TabReorder.destination(from: 1, onto: 1, count: 4) == nil)
        #expect(TabReorder.destination(from: 5, onto: 1, count: 4) == nil)
    }
}
