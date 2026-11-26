@preconcurrency import Citadel
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import RSSHKit
import Testing
@testable import RSSHRemote

@Suite struct SSHAuthFactoryTests {
    func method(_ kind: Credential.Kind) throws(SSHFailure) { _ = try SSHAuthFactory.method(username: "u", secret: kind) }

    @Test func passwordAndPlainKeysAreAccepted() throws {
        try method(.password("pw"))
        try method(.privateKey(pem: TestKeys.ed25519, passphrase: nil))
        try method(.privateKey(pem: TestKeys.rsa, passphrase: nil))
    }

    @Test func encryptedKeyErrors() {
        #expect(throws: SSHFailure.passphraseRequired) {
            try method(.privateKey(pem: TestKeys.ed25519Encrypted, passphrase: nil))
        }
        #expect(throws: SSHFailure.wrongPassphrase) {
            try method(.privateKey(pem: TestKeys.ed25519Encrypted, passphrase: "nope"))
        }
        try? method(.privateKey(pem: TestKeys.ed25519Encrypted, passphrase: "pass"))
    }
}

@Suite struct SSHLoginsTests {
    let password = Credential(label: "pw", kind: .password("secret"))
    let otherPassword = Credential(label: "pw2", kind: .password("other"))
    let ed = Credential(label: "ed", kind: .privateKey(pem: TestKeys.ed25519, passphrase: nil))
    let rsa = Credential(label: "rsa", kind: .privateKey(pem: TestKeys.rsa, passphrase: nil))

    @Test func ownCredentialFirstThenOtherKeysNeverOtherPasswords() {
        let plan = SSHLogins.plan(credential: password, vaultCredentials: [otherPassword, ed, password, rsa], agentKeys: true)
        #expect(plan.map(\.label) == ["pw", "ed", "rsa"])
    }

    @Test func noAgentKeysMeansOnlyTheOwnCredential() {
        #expect(SSHLogins.plan(credential: ed, vaultCredentials: [ed, rsa], agentKeys: false).map(\.label) == ["ed"])
        #expect(SSHLogins.plan(credential: nil, vaultCredentials: [ed, rsa], agentKeys: false).isEmpty)
    }

    @Test func ownKeyIsNotOfferedTwiceAndTheListIsCapped() {
        let keys = (0..<9).map { Credential(label: "k\($0)", kind: .privateKey(pem: TestKeys.ed25519, passphrase: nil)) }
        let plan = SSHLogins.plan(credential: keys[3], vaultCredentials: keys, agentKeys: true)
        #expect(plan.count == SSHLogins.maxOffers)
        #expect(plan.first?.label == "k3")
        #expect(Set(plan.map(\.id)).count == plan.count)
    }

    @Test func unreadableKeysAreSkippedButNothingUsableThrows() throws {
        let bad = Credential.Kind.privateKey(pem: "garbage", passphrase: nil)
        _ = try SSHLogins.method(username: "u", secrets: [bad, ed.kind])
        #expect(throws: SSHFailure.self) { try SSHLogins.method(username: "u", secrets: [bad]) }
        #expect(throws: SSHFailure.noCredential) { try SSHLogins.method(username: "u", secrets: []) }
    }

    @Test func endpointFromServerUsesTheVault() {
        let server = Server(name: "web", host: "web.example", port: 2222, username: "deploy", credentialID: ed.id)
        let pinned = KnownHost(host: "web.example", port: 2222, keyType: "ssh-ed25519", fingerprint: "SHA256:x")
        let vault = Vault(servers: [server], credentials: [password, ed, rsa], knownHosts: [pinned])
        let endpoint = SSHEndpoint(server: server, in: vault, agentKeys: true)
        #expect(endpoint.secrets == [ed.kind, rsa.kind])
        #expect(endpoint.knownHosts == [pinned])
        #expect(endpoint.port == 2222 && endpoint.username == "deploy")
        let jump = Server(name: "bastion", host: "bastion.example", username: "me", credentialID: password.id)
        let route = SSHRoute(server: server, in: vault, via: [jump], agentKeys: false)
        #expect(route.hops.map(\.host) == ["bastion.example", "web.example"])
        #expect(route.jumps[0].secrets == [password.kind])
    }

    @Test func routeFollowsTheVaultJumpChain() throws {
        var bastion = Server(name: "bastion", host: "bastion.example.com", username: "ops", credentialID: rsa.id)
        bastion.jumpHosts = [.inline(InlineJumpHost(host: "gw.example.com", username: "you"))]
        var app = Server(name: "app", host: "app.example.com", username: "deploy", credentialID: password.id)
        app.jumpHosts = [.server(bastion.id)]
        let vault = Vault(servers: [bastion, app], credentials: [password, ed, rsa])
        let route = try SSHRoute.resolve(app, in: vault, agentKeys: false)
        #expect(route.hops.map(\.host) == ["gw.example.com", "bastion.example.com", "app.example.com"])
        // The inline hop inherits bastion's key; app logs in with its password only.
        #expect(route.jumps[0].secrets == [rsa.kind])
        #expect(route.jumps[1].secrets == [rsa.kind])
        #expect(route.target.secrets == [password.kind])
        #expect(try SSHRoute.resolve(app, in: vault, agentKeys: true).target.secrets == [password.kind, ed.kind, rsa.kind])

        app.jumpHosts = [.server(app.id)]
        #expect(throws: JumpChainError.self) { try SSHRoute.resolve(app, in: Vault(servers: [app]), agentKeys: false) }
    }
}

/// The chain against a fake server conversation: offers one method per call and moves on when one fails.
@Suite struct SSHLoginChainTests {
    /// The user name of the next offer, asked on the event loop as NIOSSH does.
    static func nextUser(_ chain: SSHLoginChain, _ methods: NIOSSHAvailableUserAuthenticationMethods) throws -> String? {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        let names = promise.futureResult.map { $0?.username }
        loop.execute { chain.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise) }
        return try names.wait()
    }

    @Test func movesToTheNextMethodWhenOneIsUsedUp() throws {
        let chain = SSHLoginChain([.passwordBased(username: "a", password: "1"), .passwordBased(username: "b", password: "2")])
        #expect(try Self.nextUser(chain, .all) == "a")
        #expect(try Self.nextUser(chain, .all) == "b")
        #expect(throws: (any Error).self) { try Self.nextUser(chain, .all) }
    }

    @Test func skipsMethodsTheServerDoesNotAllow() throws {
        let key = try SSHAuthFactory.method(username: "k", secret: .privateKey(pem: TestKeys.ed25519, passphrase: nil))
        let chain = SSHLoginChain([.passwordBased(username: "p", password: "1"), key])
        #expect(try Self.nextUser(chain, .publicKey) == "k")
    }
}

@Suite struct PinnedHostKeyTests {
    // A real ed25519 public key line (the test key's).
    let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEP9isxwRgYkY8KuHc7j8dupilTD40SbQqgo1NKut8aH test"

    @Test func unknownThenPinnedThenChanged() throws {
        guard case .failure(.unknown(let presented)) = PinnedHostKeyValidator.decide(
            openSSHLine: line, host: "h", port: 22, known: []) else { Issue.record("expected unknown"); return }
        #expect(presented.keyType == "ssh-ed25519")
        if case .failure = PinnedHostKeyValidator.decide(openSSHLine: line, host: "h", port: 22, known: [presented]) {
            Issue.record("pinned key refused")
        }
        let other = KnownHost(host: "h", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:other")
        guard case .failure(.changed(let expected, _)) = PinnedHostKeyValidator.decide(
            openSSHLine: line, host: "h", port: 22, known: [other]) else { Issue.record("expected changed"); return }
        #expect(expected == other)
    }
}

@Suite struct SFTPMappingTests {
    @Test func modeBitsGiveTheKind() {
        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o040755
        #expect(SFTPFileSource.item(FilePath("/d"), attributes).kind == .directory)
        attributes.permissions = 0o100644
        attributes.size = 5
        let file = SFTPFileSource.item(FilePath("/f"), attributes)
        #expect(file.kind == .file && file.size == 5 && file.permissions == 0o644)
        attributes.permissions = 0o120777
        #expect(SFTPFileSource.item(FilePath("/l"), attributes).kind == .symlink)
    }

    @Test func networkErrorsBecomeReadable() {
        let refused = RemoteErrorMapper.failure(for: IOError(errnoCode: ECONNREFUSED, reason: "connect"), host: "h")
        #expect(refused == .hostUnreachable(host: "h", detail: RemoteErrorMapper.describe(errno: ECONNREFUSED)))
        #expect(RemoteErrorMapper.failure(for: ChannelError.connectTimeout(.seconds(1)), host: "h") == .timedOut(host: "h"))
        #expect(RemoteErrorMapper.failure(for: SSHFailure.noCredential, host: "h") == .noCredential)
        let changed = HostKeyRefusal.changed(expected: KnownHost(host: "h", port: 22, keyType: "t", fingerprint: "a"),
                                             presented: KnownHost(host: "h", port: 22, keyType: "t", fingerprint: "b"))
        #expect(RemoteErrorMapper.failure(for: changed, host: "h") == .hostKeyChanged(expected: "a", presented: "b"))
    }
}
