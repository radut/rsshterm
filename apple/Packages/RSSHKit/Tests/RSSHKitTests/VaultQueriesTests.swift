import Foundation
import Testing
@testable import RSSHKit

@Suite struct VaultQueriesTests {
    let home = ServerGroup(name: "Home")
    let password = Credential(label: "pw", kind: .password("x"))
    let key = Credential(label: "key", kind: .privateKey(pem: OpenSSHKeyVectors.ed25519PEM, passphrase: nil))
    let vault: Vault

    init() {
        vault = Vault(groups: [home], servers: [
            Server(name: "Pi hole", host: "10.0.0.2", username: "pi", groupID: home.id),
            Server(name: "web", host: "example.org", username: "deploy"),
            Server(name: "db", host: "db.internal", port: 2222, username: "postgres"),
        ], credentials: [password, key])
    }

    @Test func searchMatchesNameHostUserAndFolderIgnoringCase() {
        #expect(vault.searchingServers("PI").map(\.name) == ["Pi hole"])
        #expect(vault.searchingServers("example").map(\.name) == ["web"])
        #expect(vault.searchingServers("postgres").map(\.name) == ["db"])
        #expect(vault.searchingServers("home").map(\.name) == ["Pi hole"])
        #expect(vault.searchingServers("  ").count == 3)
        #expect(vault.searchingServers("nothing").isEmpty)
    }

    @Test func loginMethodFollowsTheCredential() {
        #expect(vault.loginMethod(for: nil) == .none)
        #expect(vault.loginMethod(for: password.id) == .password)
        #expect(vault.loginMethod(for: key.id) == .key)
        #expect(vault.loginMethod(for: UUID()) == .none)
        #expect(vault.credentials(for: .password) == [password])
        #expect(vault.credentials(for: .key) == [key])
        #expect(vault.credentials(for: .none).isEmpty)
    }

    @Test func keyInfoIsOnlyForKeys() {
        #expect(password.keyInfo == nil)
        #expect(key.keyInfo?.publicLine == OpenSSHKeyVectors.ed25519PublicLine)
        #expect(password.isPassword && key.isPrivateKey)
    }
}
