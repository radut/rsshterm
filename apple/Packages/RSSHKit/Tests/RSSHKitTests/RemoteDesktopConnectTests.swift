import Foundation
import Testing
@testable import RSSHKit

@Suite struct RemoteDesktopConnectTests {
    let password = Credential(label: "ops password", kind: .password("pw1"))
    let key = Credential(label: "ops key", kind: .privateKey(pem: OpenSSHKeyVectors.ed25519PEM, passphrase: nil))
    let macLogin = Credential(label: "mac login", kind: .password("macpw"))

    func vault(desktop: RemoteDesktop? = nil, serverCredential: UUID? = nil) throws -> (Vault, Server) {
        let gateway = Server(name: "gateway", host: "gw.example.net", username: "ops", credentialID: serverCredential)
        var v = try Vault().addingCredential(password).addingCredential(key).addingCredential(macLogin)
            .addingServer(gateway)
        if let desktop { v = try v.addingRemoteDesktop(desktop) }
        return (v, gateway)
    }

    // MARK: transport

    @Test func transportDefaultsFollowTheTunnelServer() {
        #expect(RemoteDesktop(name: "a", kind: .vnc, host: "h", tunnelServerID: UUID()).transport == .sshShared)
        #expect(RemoteDesktop(name: "a", kind: .vnc, host: "h").transport == .direct)
    }

    @Test func transportRoundTripsAndOldJSONDerivesIt() throws {
        let d = RemoteDesktop(name: "a", kind: .vnc, host: "h", tunnelServerID: UUID(), transport: .sshSeparate)
        #expect(try JSONDecoder().decode(RemoteDesktop.self, from: JSONEncoder().encode(d)).transport == .sshSeparate)
        let server = UUID()
        let old = #"{"id":"\#(UUID().uuidString)","name":"a","kind":"vnc","host":"h","tunnelServerID":"\#(server.uuidString)"}"#
        #expect(try JSONDecoder().decode(RemoteDesktop.self, from: Data(old.utf8)).transport == .sshShared)
        let unknown = #"{"id":"\#(UUID().uuidString)","name":"a","kind":"vnc","host":"h","transport":"quic"}"#
        #expect(try JSONDecoder().decode(RemoteDesktop.self, from: Data(unknown.utf8)).transport == .direct)
    }

    @Test func sshTransportsNeedAServer() throws {
        let (v, _) = try vault()
        #expect(throws: VaultEditError.needsTunnelServer) {
            try v.addingRemoteDesktop(RemoteDesktop(name: "a", kind: .vnc, host: "h", transport: .sshSeparate))
        }
    }

    @Test func routeSaysWhetherTheOpenSessionIsReused() throws {
        let (v, gw) = try vault()
        let shared = RemoteDesktop(name: "a", kind: .vnc, host: "localhost", tunnelServerID: gw.id)
        let separate = RemoteDesktop(name: "b", kind: .vnc, host: "localhost", tunnelServerID: gw.id,
                                     transport: .sshSeparate)
        #expect(try v.route(for: shared).reusesOpenSession)
        #expect(try !v.route(for: separate).reusesOpenSession)
        #expect(try v.route(for: separate).sshServer == gw)
        // A direct entry ignores a leftover server.
        let direct = RemoteDesktop(name: "c", kind: .rdp, host: "10.0.0.5", tunnelServerID: gw.id, transport: .direct)
        #expect(try v.route(for: direct).sshServer == nil)
        #expect(try v.route(for: direct).warnings == [.notTunnelled])
    }

    // MARK: Copy from SSH

    @Test func copyFromSSHTakesUserAndPassword() throws {
        let (v, gw) = try vault(serverCredential: password.id)
        let d = RemoteDesktop(name: "Win", kind: .rdp, host: "10.0.0.5", tunnelServerID: gw.id)
        let copied = try d.copyingLogin(from: gw.id, in: v)
        #expect(copied.username == "ops")
        #expect(copied.credentialID == password.id)   // the same vault item, not a copy
        #expect(d.username == nil)                    // the original is untouched
    }

    @Test func copyFromSSHWithAKeyTakesOnlyTheUser() throws {
        let (v, gw) = try vault(serverCredential: key.id)
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", credentialID: macLogin.id,
                              tunnelServerID: gw.id)
        let copied = try d.copyingLogin(from: gw.id, in: v)
        #expect(copied.username == "ops")
        #expect(copied.credentialID == macLogin.id)   // keeps the password it had
    }

    @Test func copyFromAServerThatIsGoneFails() throws {
        let (v, _) = try vault()
        #expect(throws: VaultEditError.unknownServer) {
            try RemoteDesktop(name: "a", kind: .vnc, host: "h").copyingLogin(from: UUID(), in: v)
        }
    }

    // MARK: connect plan

    @Test func aSavedLoginConnectsAtOnce() throws {
        let (v, gw) = try vault()
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "me",
                              credentialID: macLogin.id, tunnelServerID: gw.id)
        #expect(RemoteDesktopConnectPlan.start(d, in: v)
            == .connect(RemoteDesktopLogin(username: "me", password: "macpw")))
    }

    @Test func noSavedLoginAsksWithTheUserFilledAndSavedPasswordsListed() throws {
        let (v, gw) = try vault()
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "me",
                              tunnelServerID: gw.id)
        guard case .askLogin(let sheet) = RemoteDesktopConnectPlan.start(d, in: v) else {
            Issue.record("expected the sheet")
            return
        }
        #expect(sheet.username == "me")
        #expect(sheet.needsUsername)
        #expect(sheet.savedPasswords.map(\.id) == [password.id, macLogin.id])   // keys are never offered
        #expect(sheet.error == nil)
    }

    @Test func askEveryTimeShowsTheSheetEvenWithASavedLogin() throws {
        let (v, gw) = try vault()
        let d = RemoteDesktop(name: "Mac", kind: .vnc, host: "localhost", credentialID: macLogin.id,
                              tunnelServerID: gw.id, askEveryTime: true)
        guard case .askLogin(let sheet) = RemoteDesktopConnectPlan.start(d, in: v) else {
            Issue.record("expected the sheet")
            return
        }
        #expect(sheet.preselected == macLogin.id)
        #expect(!sheet.needsUsername)   // a VNC password has no user
    }

    @Test func aDirectEntryAsksForConfirmationFirst() throws {
        let (v, _) = try vault()
        let d = RemoteDesktop(name: "pi", kind: .vnc, host: "pi.lan", credentialID: macLogin.id)
        #expect(RemoteDesktopConnectPlan.start(d, in: v) == .confirmDirect(.notEncrypted))
        #expect(RemoteDesktopConnectPlan.start(d, in: v, directConfirmed: true)
            == .connect(RemoteDesktopLogin(username: nil, password: "macpw")))
        let rdp = RemoteDesktop(name: "w", kind: .rdp, host: "10.0.0.5", username: "a", credentialID: macLogin.id)
        #expect(RemoteDesktopConnectPlan.start(rdp, in: v) == .confirmDirect(.exposedPort))
    }

    @Test func sheetChoices() throws {
        let (v, gw) = try vault()
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "me",
                              tunnelServerID: gw.id)
        #expect(RemoteDesktopConnectPlan.resolve(.saved(macLogin.id, username: "me"), for: d, in: v)
            == .init(login: RemoteDesktopLogin(username: "me", password: "macpw"), saveOnSuccess: nil))
        #expect(RemoteDesktopConnectPlan.resolve(.withoutLogin, for: d, in: v) == .init(login: nil, saveOnSuccess: nil))
        let typed = RemoteDesktopConnectPlan.resolve(.typed(username: "me", password: "new", save: true), for: d, in: v)
        #expect(typed.login == RemoteDesktopLogin(username: "me", password: "new"))
        #expect(typed.saveOnSuccess?.label == "me@Mac")
        let unsaved = RemoteDesktopConnectPlan.resolve(.typed(username: "me", password: "x", save: false), for: d, in: v)
        #expect(unsaved.saveOnSuccess == nil)
    }

    @Test func aTypedLoginIsSavedOnlyAfterItWorked() throws {
        let (v, gw) = try vault()
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", tunnelServerID: gw.id)
        let v2 = try v.addingRemoteDesktop(d)
        let typed = RemoteDesktopConnectPlan.resolve(.typed(username: "me", password: "new", save: true), for: d, in: v2)
        let saved = try v2.savingRemoteDesktopLogin(try #require(typed.saveOnSuccess), username: "me", for: d.id)
        let entry = try #require(saved.remoteDesktops.first)
        #expect(entry.username == "me")
        #expect(saved.credentials.first { $0.id == entry.credentialID }?.kind == .password("new"))
    }

    @Test func afterAWrongPasswordTheSheetComesBackWithTheReason() throws {
        let (v, gw) = try vault()
        let d = RemoteDesktop(name: "Mac", kind: .appleScreenSharing, host: "localhost", username: "me",
                              credentialID: macLogin.id, tunnelServerID: gw.id)
        guard case .askLogin(let sheet) = RemoteDesktopConnectPlan.afterAuthFailure(d, in: v, reason: "Authentication failed")
        else {
            Issue.record("expected the sheet")
            return
        }
        #expect(sheet.error == "Wrong password for me@Mac. Authentication failed")
        #expect(sheet.preselected == macLogin.id)
    }
}
