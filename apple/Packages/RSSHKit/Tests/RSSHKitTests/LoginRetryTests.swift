import Foundation
import Testing
@testable import RSSHKit

@Suite struct LoginRetryTests {
    let key = Credential(label: "laptop", kind: .password("unused"))
    let serverID = UUID()

    var saved: LoginRetryFlow.SavedLogin {
        .init(serverID: serverID, serverName: "sv1", username: "root", credentialID: UUID())
    }

    func attempt(_ user: String, _ login: QuickLogin) -> LoginAttempt { LoginAttempt(username: user, login: login) }

    var keyLogin: QuickLogin {
        QuickLogin(label: "ops key", secret: .privateKey(pem: "pem", passphrase: nil), credentialID: UUID())
    }

    // MARK: which failures offer another login

    @Test(arguments: [SSHFailure.authenticationFailed, .noCredential, .wrongPassphrase, .passphraseRequired,
                      .invalidKey("bad"), .unsupportedKey("dsa")])
    func loginFailuresOfferAnotherLogin(_ failure: SSHFailure) {
        #expect(failure.offersOtherLogin)
    }

    @Test(arguments: [SSHFailure.timedOut(host: "h"), .hostUnreachable(host: "h", detail: "x"), .unknown("reset"),
                      .hostKeyRejectedByUser, .hostKeyChanged(expected: "a", presented: "b"), .shellFailed("x"),
                      .viaJumpHost("bastion", .authenticationFailed)])
    func networkHostKeyAndJumpFailuresDoNot(_ failure: SSHFailure) {
        #expect(!failure.offersOtherLogin)
    }

    // MARK: the state machine

    @Test func refusedLoginOffersThePicker() {
        var flow = LoginRetryFlow(saved: saved)
        flow.failed(.authenticationFailed)
        #expect(flow.phase == .offering(.authenticationFailed))
        #expect(flow.offersOtherLogin)
        flow.openPicker()
        #expect(flow.phase == .picking(.authenticationFailed))
        flow.closePicker()
        #expect(flow.phase == .offering(.authenticationFailed))
    }

    @Test func networkFailureOffersNothing() {
        var flow = LoginRetryFlow(saved: saved)
        flow.failed(.timedOut(host: "sv1"))
        #expect(flow.phase == .idle)
        flow.openPicker()
        #expect(flow.phase == .idle)
    }

    @Test func successWithAnotherUserAndKeyOffersToUpdateTheServer() {
        var flow = LoginRetryFlow(saved: saved)
        flow.failed(.authenticationFailed)
        flow.openPicker()
        let tried = attempt("ubuntu", keyLogin)
        flow.choose(tried)
        #expect(flow.phase == .trying(tried))
        flow.connected()
        let offer = LoginSaveOffer.updateServer(serverID: serverID, serverName: "sv1", attempt: tried)
        #expect(flow.phase == .offeringSave(offer))
        #expect(offer.message == "Save ubuntu + key ops key for sv1?")
        flow.dismissSave()
        #expect(flow.phase == .idle)
    }

    @Test func failingAgainKeepsTheBannerAndNeverLoops() {
        var flow = LoginRetryFlow(saved: saved)
        flow.failed(.authenticationFailed)
        flow.openPicker()
        flow.choose(attempt("ubuntu", keyLogin))
        flow.failed(.authenticationFailed)
        #expect(flow.phase == .offering(.authenticationFailed))
        #expect(flow.lastAttempt?.username == "ubuntu")
        flow.openPicker()
        #expect(flow.phase == .picking(.authenticationFailed))
    }

    @Test func theSameLoginAsSavedOffersNoSave() {
        let saved = saved
        var flow = LoginRetryFlow(saved: saved)
        flow.failed(.authenticationFailed)
        flow.openPicker()
        let same = QuickLogin(label: "k", secret: .password("x"), credentialID: saved.credentialID)
        flow.choose(attempt("root", same))
        flow.connected()
        #expect(flow.phase == .idle)
    }

    @Test func plainConnectWithoutAPickedLoginOffersNoSave() {
        var flow = LoginRetryFlow(saved: saved)
        flow.connected()
        #expect(flow.phase == .idle)
        flow.failed(.authenticationFailed)
        flow.connected() // a plain Retry that worked
        #expect(flow.phase == .idle)
    }

    @Test func quickConnectSessionOffersToSaveTheServer() {
        var flow = LoginRetryFlow(saved: nil)
        flow.failed(.authenticationFailed)
        flow.openPicker()
        let tried = attempt("ubuntu", QuickLogin(label: "password", secret: .password("pw")))
        flow.choose(tried)
        flow.connected()
        #expect(flow.phase == .offeringSave(.saveServer(attempt: tried)))
    }

    @Test func messagesNameUserAndLogin() {
        let typed = attempt("ubuntu", QuickLogin(label: "password", secret: .password("pw")))
        #expect(LoginSaveOffer.updateServer(serverID: serverID, serverName: "web", attempt: typed).message
                == "Save ubuntu + password for web?")
        let asked = attempt("deploy", QuickLogin(label: "password", secret: .password("")))
        #expect(LoginSaveOffer.updateServer(serverID: serverID, serverName: "web", attempt: asked).message
                == "Save user deploy for web?")
        #expect(LoginSaveOffer.saveServer(attempt: typed).message == "Save this server with ubuntu + password?")
    }

    // MARK: saving into the vault

    func vault(with server: Server, credentials: [Credential] = []) throws -> Vault {
        var vault = Vault()
        for credential in credentials { vault = try vault.addingCredential(credential) }
        return try vault.addingServer(server)
    }

    @Test func saveLinksAnExistingVaultKey() throws {
        let old = Credential(label: "old", kind: .password("o"))
        let newKey = Credential(label: "ops key", kind: .password("k"))
        let server = Server(name: "sv1", host: "10.0.0.5", port: 22, username: "root", credentialID: old.id)
        let start = try vault(with: server, credentials: [old, newKey])
        let tried = attempt("ubuntu", QuickLogin(credential: newKey))
        let next = try start.savingLogin(tried, forServer: server.id)
        let updated = try #require(next.servers.first)
        #expect(updated.username == "ubuntu")
        #expect(updated.credentialID == newKey.id)
        #expect(next.credentials.count == 2)
        #expect(start.servers.first?.username == "root") // the old vault is untouched
    }

    @Test func saveStoresATypedPasswordAsANewCredential() throws {
        let server = Server(name: "sv1", host: "10.0.0.5", port: 22, username: "root", credentialID: nil)
        let start = try vault(with: server)
        let tried = attempt("ubuntu", QuickLogin(label: "password", secret: .password("s3cret")))
        let next = try start.savingLogin(tried, forServer: server.id)
        let updated = try #require(next.servers.first)
        let credential = try #require(next.credentials.first)
        #expect(credential.kind == .password("s3cret"))
        #expect(credential.label == "ubuntu@10.0.0.5 password")
        #expect(updated.credentialID == credential.id)
        #expect(updated.username == "ubuntu")
    }

    @Test func aPasswordAskedByTheTerminalSavesOnlyTheUser() throws {
        let old = Credential(label: "old", kind: .password("o"))
        let server = Server(name: "sv1", host: "h", port: 22, username: "root", credentialID: old.id)
        let start = try vault(with: server, credentials: [old])
        let next = try start.savingLogin(attempt("deploy", QuickLogin(label: "password", secret: .password(""))),
                                         forServer: server.id)
        #expect(next.servers.first?.username == "deploy")
        #expect(next.servers.first?.credentialID == old.id)
        #expect(next.credentials.count == 1)
    }

    @Test func saveForAnUnknownServerThrows() throws {
        let start = Vault()
        #expect(throws: VaultEditError.unknownServer) {
            try start.savingLogin(attempt("u", QuickLogin(label: "p", secret: .password("x"))), forServer: UUID())
        }
    }
}
