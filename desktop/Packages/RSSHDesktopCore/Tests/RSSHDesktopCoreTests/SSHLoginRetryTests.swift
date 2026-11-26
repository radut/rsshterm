import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@Suite struct SSHLoginRetryTests {
    // MARK: what ended the ssh pane

    @Test(arguments: [
        "root@10.0.0.5: Permission denied (publickey).",
        "ubuntu@web: Permission denied (publickey,password).",
        "Received disconnect from 10.0.0.5 port 22:2: Too many authentication failures",
        "Load key \"/x\": invalid format\r\nroot@h: Permission denied (publickey).\r\n",
    ])
    func refusedLoginsAreRecognised(_ output: String) {
        #expect(SSHExitDiagnosis.refusedLogin(exitCode: 255, output: "Welcome\r\n" + output))
    }

    @Test(arguments: [
        "ssh: connect to host 10.0.0.5 port 22: Connection refused",
        "ssh: Could not resolve hostname nope: Name or service not known",
        "ssh: connect to host 10.0.0.5 port 22: Operation timed out",
        "Host key verification failed.",
    ])
    func networkAndHostKeyFailuresAreNot(_ output: String) {
        #expect(!SSHExitDiagnosis.refusedLogin(exitCode: 255, output: output))
    }

    @Test func onlyStatus255Counts() {
        // A shell that printed "Permission denied" and exited 1 is not a refused ssh login.
        #expect(!SSHExitDiagnosis.refusedLogin(exitCode: 1, output: "cat: x: Permission denied (publickey)"))
        #expect(!SSHExitDiagnosis.refusedLogin(exitCode: 0, output: "Permission denied (publickey)."))
    }

    @Test func onlyTheLastLinesCount() {
        let old = "root@h: Permission denied (publickey).\r\n" + String(repeating: "ls output\r\n", count: 40)
        #expect(!SSHExitDiagnosis.refusedLogin(exitCode: 255, output: old + "Connection to h closed by remote host."))
    }

    // MARK: the arguments of another login

    @Test func aKeyLoginOffersThatKeyFirstAsTheNewUser() {
        let id = UUID()
        let override = SSHLoginOverride(username: "ubuntu",
                                        login: .key(credentialID: id, label: "ops", publicKeyFile: "/k/ops.pub"),
                                        markerFile: "/run/m")
        #expect(override.arguments == [
            "-l", "ubuntu",
            "-o", "IdentityFile=/k/ops.pub", "-o", "IdentitiesOnly=yes",
            "-o", "PermitLocalCommand=yes", "-o", "LocalCommand=touch '/run/m'",
        ])
        #expect(override.attempt.username == "ubuntu")
        #expect(override.attempt.login.credentialID == id)
        #expect(override.attempt.login.label == "ops")
    }

    @Test func aPasswordIsAskedBySSHInTheTerminal() {
        let override = SSHLoginOverride(username: "admin", login: .askPassword, markerFile: "/run/m")
        #expect(override.arguments == [
            "-l", "admin",
            "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive,password",
            "-o", "PermitLocalCommand=yes", "-o", "LocalCommand=touch '/run/m'",
        ])
        // Nothing secret is known: saving keeps the server's login and stores the user.
        #expect(override.attempt.login.secret == .password(""))
        #expect(override.attempt.login.credentialID == nil)
    }

    @Test func percentAndQuotesInPathsAreEscaped() {
        let override = SSHLoginOverride(username: "u", login: .askPassword, markerFile: "/tmp/a'b%c")
        #expect(override.arguments.last == "LocalCommand=touch '/tmp/a'\\''b%%c'")
    }

    @Test func badUserNamesAreRejected() {
        #expect(SSHLoginOverride.validUsername(" ubuntu ") == "ubuntu")
        #expect(SSHLoginOverride.validUsername("") == nil)
        #expect(SSHLoginOverride.validUsername("a b") == nil)
        #expect(SSHLoginOverride.validUsername("-oProxyCommand=x") == nil)
    }

    // MARK: the whole round on a pane

    @Test func paneRoundFailurePickerSuccessSave() throws {
        let key = Credential(label: "ops", kind: .password("x"))
        let old = Credential(label: "old", kind: .password("o"))
        let server = Server(name: "web", host: "10.0.0.5", username: "root", credentialID: old.id)
        var flow = LoginRetryFlow(saved: .init(serverID: server.id, serverName: server.name,
                                               username: server.username, credentialID: server.credentialID))
        flow.failed(.authenticationFailed)
        flow.openPicker()
        let override = SSHLoginOverride(username: "ubuntu",
                                        login: .key(credentialID: key.id, label: "ops", publicKeyFile: "/k"),
                                        markerFile: "/m")
        flow.choose(override.attempt)
        flow.connected()
        let offer = try #require(flow.saveOffer)
        #expect(offer.message == "Save ubuntu + key ops for web?")
        let vault = try Vault(servers: [server], credentials: [old, key]).savingLogin(offer.attempt, forServer: server.id)
        #expect(vault.servers.first?.username == "ubuntu")
        #expect(vault.servers.first?.credentialID == key.id)
    }
}

@Suite struct PaneLoginRetryTests {
    let old = UUID()
    var server: Server { Server(name: "web", host: "10.0.0.5", username: "root", credentialID: old) }
    let key = PaneLoginRetry.KeyOption(credentialID: UUID(), label: "ops", publicLine: "ssh-ed25519 AAAA ops")

    @Test func usersStartWithTheServersOwn() {
        #expect(PaneLoginRetry.users(current: "admin", quickUsers: ["root", "admin", "ubuntu"]) == ["admin", "root", "ubuntu"])
    }

    @Test func aKeyChoiceWritesItsPublicHalfAndConnectsAsTheNewUser() throws {
        var retry = PaneLoginRetry(server: server)
        retry.refused()
        #expect(retry.flow.offersOtherLogin)
        retry.openPicker()
        let chosen = retry.choose(username: " ubuntu ", choice: .key(key.credentialID), keys: [key],
                                  keyDirectory: "/k", markerDirectory: "/run")
        let launch = try #require(chosen)
        #expect(launch.publicKey?.path == "/k/\(key.credentialID.uuidString.lowercased()).pub")
        #expect(launch.publicKey?.content == "ssh-ed25519 AAAA ops\n")
        #expect(launch.override.username == "ubuntu")
        #expect(launch.override.markerFile.hasPrefix("/run/rssh-login-"))
        #expect(retry.flow.phase == .trying(launch.override.attempt))
        retry.loggedIn()
        #expect(retry.flow.saveOffer?.message == "Save ubuntu + key ops for web?")
    }

    @Test func badChoicesStartNothing() {
        var retry = PaneLoginRetry(server: server)
        retry.refused()
        #expect(retry.choose(username: "a b", choice: .askPassword, keys: [], keyDirectory: "/k", markerDirectory: "/r") == nil)
        #expect(retry.choose(username: "u", choice: .key(UUID()), keys: [key], keyDirectory: "/k", markerDirectory: "/r") == nil)
        #expect(retry.flow.offersOtherLogin)
    }

    @Test func refusedAgainOffersThePickerAgain() throws {
        var retry = PaneLoginRetry(server: server)
        retry.refused()
        let chosen = retry.choose(username: "u", choice: .askPassword, keys: [], keyDirectory: "/k", markerDirectory: "/r")
        #expect(chosen != nil)
        retry.refused()
        #expect(retry.flow.offersOtherLogin)
        #expect(retry.override?.username == "u") // Retry runs the last attempt again
    }
}
