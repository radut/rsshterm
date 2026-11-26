import Foundation
import Testing
@testable import RSSHKit

@Suite struct RemoteDesktopTests {
    let password = Credential(label: "mac login", kind: .password("s3cret"))
    let key = Credential(label: "ed25519", kind: .privateKey(pem: OpenSSHKeyVectors.ed25519PEM, passphrase: nil))
    let bastion = Server(name: "bastion", host: "gw.example.net", username: "ops")

    // MARK: model

    @Test(arguments: [(RemoteDesktop.Kind.vnc, 5900), (.appleScreenSharing, 5900), (.rdp, 3389)])
    func defaultPortFollowsTheKind(kind: RemoteDesktop.Kind, port: Int) {
        #expect(kind.defaultPort == port)
        #expect(RemoteDesktop(name: "x", kind: kind, host: "h").port == port)
    }

    @Test func onlyAppleScreenSharingAndRDPAskForAUsername() {
        #expect(!RemoteDesktop.Kind.vnc.usesUsername)
        #expect(RemoteDesktop.Kind.appleScreenSharing.usesUsername)
        #expect(RemoteDesktop.Kind.rdp.usesUsername)
    }

    @Test func codableRoundTrip() throws {
        let d = RemoteDesktop(name: "Studio Mac", kind: .appleScreenSharing, host: "127.0.0.1", port: 5900,
                              username: "me", credentialID: UUID(), groupID: UUID(), tunnelServerID: UUID())
        #expect(try JSONDecoder().decode(RemoteDesktop.self, from: JSONEncoder().encode(d)) == d)
        let r = RemoteDesktop(name: "Win", kind: .rdp, host: "10.0.0.5", username: "admin", domain: "CORP")
        #expect(try JSONDecoder().decode(RemoteDesktop.self, from: JSONEncoder().encode(r)) == r)
    }

    @Test func minimalJSONDecodesWithDefaults() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"pi","kind":"vnc","host":"localhost"}"#
        let d = try JSONDecoder().decode(RemoteDesktop.self, from: Data(json.utf8))
        #expect(d.port == 5900)
        #expect(d.tunnelServerID == nil)
        #expect(d.username == nil)
        #expect(d.isTunnelled == false)
        #expect(d.shareClipboard == false)   // clipboard sharing is opt-in
    }

    @Test func clipboardOptInRoundTripsAndIsOnlyWrittenWhenOn() throws {
        let on = RemoteDesktop(name: "x", kind: .vnc, host: "h", shareClipboard: true)
        #expect(try JSONDecoder().decode(RemoteDesktop.self, from: JSONEncoder().encode(on)).shareClipboard)
        let off = String(decoding: try JSONEncoder().encode(RemoteDesktop(name: "x", kind: .vnc, host: "h")),
                         as: UTF8.self)
        #expect(!off.contains("shareClipboard"))
    }

    @Test func unknownKindFromANewerBuildFailsThatEntryOnly() throws {
        let good = RemoteDesktop(name: "ok", kind: .vnc, host: "h")
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let vaultJSON = #"{"version":1,"groups":[],"servers":[],"credentials":[],"remoteDesktops":[\#(goodJSON),"#
            + #"{"id":"\#(UUID().uuidString)","name":"new","kind":"spice","host":"h"}]}"#
        let vault = try JSONDecoder().decode(Vault.self, from: Data(vaultJSON.utf8))
        #expect(vault.remoteDesktops == [good])
    }

    // MARK: vault compatibility

    @Test func oldVaultWithoutRemoteDesktopsOpens() throws {
        let json = #"{"version":1,"groups":[],"servers":[],"credentials":[]}"#
        let vault = try JSONDecoder().decode(Vault.self, from: Data(json.utf8))
        #expect(vault.remoteDesktops.isEmpty)
    }

    @Test func vaultWithoutRemoteDesktopsEncodesNoKey() throws {
        let data = try JSONEncoder().encode(Vault(servers: [bastion]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["remoteDesktops"] == nil)
        #expect(object["servers"] != nil)
    }

    @Test func vaultRoundTripKeepsRemoteDesktopsAndEverythingElse() throws {
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "me",
                              credentialID: password.id, tunnelServerID: bastion.id)
        let vault = Vault(servers: [bastion], credentials: [password], remoteDesktops: [d])
        let back = try JSONDecoder().decode(Vault.self, from: JSONEncoder().encode(vault))
        #expect(back == vault)
        // Sealed and opened like any vault.
        let key = VaultCipher.newVaultKey()
        #expect(try VaultCipher.open(VaultCipher.seal(vault, key: key), key: key) == vault)
    }

    // MARK: edits

    func base() throws -> Vault {
        try Vault().addingCredential(password).addingServer(bastion)
    }

    @Test func addUpdateDelete() throws {
        var d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "me",
                              credentialID: password.id, tunnelServerID: bastion.id)
        var vault = try base().addingRemoteDesktop(d)
        #expect(vault.remoteDesktops == [d])
        d.name = "Mac mini"
        vault = try vault.updatingRemoteDesktop(d)
        #expect(vault.remoteDesktops.first?.name == "Mac mini")
        vault = try vault.deletingRemoteDesktops([d.id])
        #expect(vault.remoteDesktops.isEmpty)
    }

    @Test func editsLeaveTheOriginalVaultAsItWas() throws {
        let original = try base()
        _ = try original.addingRemoteDesktop(RemoteDesktop(name: "x", kind: .vnc, host: "h"))
        #expect(original.remoteDesktops.isEmpty)
    }

    @Test func refusesDuplicatesAndUnknownIDs() throws {
        let d = RemoteDesktop(name: "x", kind: .vnc, host: "h")
        let vault = try base().addingRemoteDesktop(d)
        #expect(throws: VaultEditError.duplicateID) { try vault.addingRemoteDesktop(d) }
        #expect(throws: VaultEditError.unknownRemoteDesktop) {
            try vault.updatingRemoteDesktop(RemoteDesktop(name: "y", kind: .vnc, host: "h"))
        }
        #expect(throws: VaultEditError.unknownRemoteDesktop) { try vault.deletingRemoteDesktops([UUID()]) }
    }

    @Test func refusesBadLinksAndFields() throws {
        let vault = try base().addingCredential(key)
        #expect(throws: VaultEditError.unknownServer) {
            try vault.addingRemoteDesktop(RemoteDesktop(name: "x", kind: .vnc, host: "h", tunnelServerID: UUID()))
        }
        #expect(throws: VaultEditError.unknownCredential) {
            try vault.addingRemoteDesktop(RemoteDesktop(name: "x", kind: .vnc, host: "h", credentialID: UUID()))
        }
        #expect(throws: VaultEditError.unknownGroup) {
            try vault.addingRemoteDesktop(RemoteDesktop(name: "x", kind: .vnc, host: "h", groupID: UUID()))
        }
        // A screen is opened with a password, never with an SSH key.
        #expect(throws: VaultEditError.needsPassword) {
            try vault.addingRemoteDesktop(RemoteDesktop(name: "x", kind: .vnc, host: "h", credentialID: key.id))
        }
        #expect(throws: VaultEditError.emptyName) {
            try vault.addingRemoteDesktop(RemoteDesktop(name: "  ", kind: .vnc, host: "h"))
        }
        #expect(throws: VaultEditError.invalidAddress(.emptyHost)) {
            try vault.addingRemoteDesktop(RemoteDesktop(name: "x", kind: .vnc, host: " "))
        }
        #expect(throws: VaultEditError.invalidAddress(.invalidPort)) {
            try vault.addingRemoteDesktop(RemoteDesktop(name: "x", kind: .vnc, host: "h", port: 70000))
        }
    }

    @Test func savedNameAndHostAreTrimmed() throws {
        let vault = try base().addingRemoteDesktop(RemoteDesktop(name: " Mac ", kind: .vnc, host: " mac.lan "))
        #expect(vault.remoteDesktops.first?.name == "Mac")
        #expect(vault.remoteDesktops.first?.host == "mac.lan")
    }

    @Test func tunnelServerAndPasswordCannotBeDeletedWhileUsed() throws {
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "me",
                              credentialID: password.id, tunnelServerID: bastion.id)
        let vault = try base().addingRemoteDesktop(d)
        #expect(throws: VaultEditError.serverInUse(["Mac"])) { try vault.deletingServers([bastion.id]) }
        #expect(throws: VaultEditError.credentialInUse(["Mac"])) { try vault.deletingCredential(password.id) }
        #expect(vault.remoteDesktops(tunnelledThrough: bastion.id) == [d])
    }

    @Test func deletingAFolderUngroupsItsRemoteDesktops() throws {
        let folder = ServerGroup(name: "Office")
        let d = RemoteDesktop(name: "x", kind: .vnc, host: "h", groupID: folder.id)
        let vault = try base().addingGroup(folder).addingRemoteDesktop(d).deletingGroup(folder.id)
        #expect(vault.remoteDesktops.first?.groupID == nil)
    }

    // MARK: route

    @Test func directRouteGoesToTheHost() throws {
        let d = RemoteDesktop(name: "pi", kind: .vnc, host: "pi.lan", port: 5901)
        let route = try base().route(for: d)
        #expect(route.sshServer == nil)
        #expect(route.target == RemoteDesktopTarget(host: "pi.lan", port: 5901))
        #expect(route.warnings == [.notTunnelled])
    }

    @Test func tunnelledRouteGoesThroughTheServerAndHostIsSeenFromThere() throws {
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", tunnelServerID: bastion.id)
        let route = try base().route(for: d)
        #expect(route.sshServer == bastion)
        #expect(route.target == RemoteDesktopTarget(host: "localhost", port: 5900))
        #expect(route.warnings.isEmpty)
    }

    @Test func routeToAServerThatIsGoneFails() throws {
        let d = RemoteDesktop(name: "Mac", kind: .vnc, host: "localhost", tunnelServerID: UUID())
        #expect(throws: VaultEditError.unknownServer) { try base().route(for: d) }
    }

    // MARK: Screen Sharing URL

    @Test func screenSharingURLPointsAtTheLocalTunnel() throws {
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "me")
        #expect(d.screenSharingURL(localPort: 50123)?.absoluteString == "vnc://me@127.0.0.1:50123")
        let v = RemoteDesktop(name: "pi", kind: .vnc, host: "localhost")
        #expect(v.screenSharingURL(localPort: 50123)?.absoluteString == "vnc://127.0.0.1:50123")
    }

    @Test func screenSharingURLEscapesTheUsernameAndNeverCarriesAPassword() throws {
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "a b@c",
                              credentialID: password.id)
        let url = try #require(d.screenSharingURL(localPort: 50123))
        #expect(url.absoluteString == "vnc://a%20b%40c@127.0.0.1:50123")
        #expect(!url.absoluteString.contains("s3cret"))
    }

    @Test func screenSharingRefusesPort5900OnThisMachineAndRDP() {
        // Screen Sharing.app treats 127.0.0.1:5900 as "this Mac" and refuses it.
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost")
        #expect(d.screenSharingURL(localPort: 5900) == nil)
        #expect(d.screenSharingURL(localPort: 0) == nil)
        #expect(RemoteDesktop(name: "w", kind: .rdp, host: "h").screenSharingURL(localPort: 50123) == nil)
    }
}
