import Foundation
import Testing
@testable import RSSHKit

@Suite struct JumpHostModelTests {
    @Test func oldServerJSONDecodesWithoutJumps() throws {
        let json = #"{"id":"7B2D2A9E-55C1-4C51-9E0B-8C2F0B3E9D11","name":"web","host":"web.example.com","port":22,"username":"deploy"}"#
        let server = try JSONDecoder().decode(Server.self, from: Data(json.utf8))
        #expect(server.jumpHosts.isEmpty)
        // and a server without jumps writes no key, so older builds read it unchanged
        let back = String(decoding: try JSONEncoder().encode(server), as: UTF8.self)
        #expect(!back.contains("jumpHosts"))
    }

    @Test func roundTripsBothKinds() throws {
        let bastion = UUID()
        let key = UUID()
        var server = Server(name: "db", host: "10.0.0.5", username: "postgres")
        server.jumpHosts = [.server(bastion),
                            .inline(InlineJumpHost(host: "gw.example.com", port: 2222, username: "ops", credentialID: key)),
                            .inline(InlineJumpHost(host: "fe80::1", username: "root"))]
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(Server.self, from: data)
        #expect(decoded.jumpHosts == server.jumpHosts)
        #expect(decoded == server)
    }

    @Test func entryFormatIsFlat() throws {
        let id = UUID()
        let text = String(decoding: try JSONEncoder().encode(JumpHost.server(id)), as: UTF8.self)
        #expect(text == #"{"serverID":"\#(id.uuidString)"}"#)
    }

    @Test func unreadableEntryFailsOnlyTheJumpList() throws {
        let json = #"{"id":"7B2D2A9E-55C1-4C51-9E0B-8C2F0B3E9D11","name":"web","host":"h","port":22,"username":"u","jumpHosts":[{"what":1}]}"#
        let server = try JSONDecoder().decode(Server.self, from: Data(json.utf8))
        #expect(server.name == "web")
    }

    @Test func inlineDisplayName() {
        #expect(InlineJumpHost(host: "gw", username: "ops").displayName == "ops@gw")
        #expect(InlineJumpHost(host: "gw", port: 2222, username: "ops").displayName == "ops@gw:2222")
        #expect(InlineJumpHost(host: "fe80::1", port: 2222, username: "ops").displayName == "ops@[fe80::1]:2222")
    }

    @Test func draftCarriesJumps() throws {
        var server = Server(name: "db", host: "db", username: "u")
        server.jumpHosts = [.inline(InlineJumpHost(host: "gw", username: "ops"))]
        let made = try ServerDraft(server: server).makeServer(id: server.id)
        #expect(made.jumpHosts == server.jumpHosts)
    }
}

@Suite struct JumpChainTests {
    let key = UUID()
    let otherKey = UUID()

    func server(_ name: String, _ host: String, user: String = "u", port: Int = 22, credential: UUID? = nil,
                via: [JumpHost] = []) -> Server {
        var s = Server(name: name, host: host, port: port, username: user, credentialID: credential)
        s.jumpHosts = via
        return s
    }

    @Test func noJumpsIsTheServerAlone() throws {
        let web = server("web", "web.example.com", credential: key)
        let hops = try JumpChain.hops(to: web, in: [web])
        #expect(hops == [ConnectionHop(name: "web", target: ConnectionTarget(host: "web.example.com", port: 22, username: "u"),
                                       credentialID: key, serverID: web.id)])
    }

    @Test func vaultServerHopUsesItsOwnUserPortAndKey() throws {
        let bastion = server("bastion", "bastion.example.com", user: "jump", port: 2200, credential: otherKey)
        let db = server("db", "10.0.0.5", user: "postgres", credential: key, via: [.server(bastion.id)])
        let hops = try JumpChain.hops(to: db, in: [bastion, db])
        #expect(hops.map(\.name) == ["bastion", "db"])
        #expect(hops[0].target == ConnectionTarget(host: "bastion.example.com", port: 2200, username: "jump"))
        #expect(hops[0].credentialID == otherKey)
        #expect(hops[0].serverID == bastion.id)
        #expect(hops[1].credentialID == key)
    }

    @Test func inlineHopWithoutCredentialInheritsOnlyAKey() throws {
        let db = server("db", "10.0.0.5", credential: key,
                        via: [.inline(InlineJumpHost(host: "gw", port: 2222, username: "ops")),
                              .inline(InlineJumpHost(host: "gw2", username: "ops", credentialID: otherKey))])
        let hops = try JumpChain.hops(to: db, in: [db], inheritable: [key])
        #expect(hops.map(\.name) == ["ops@gw:2222", "ops@gw2", "db"])
        #expect(hops[0].credentialID == key)
        #expect(hops[1].credentialID == otherKey)
        #expect(hops[0].serverID == nil)
        // a login not known to be a key (a password) is never handed to the jump host
        #expect(try JumpChain.hops(to: db, in: [db])[0].credentialID == nil)
    }

    @Test func inlineHopOfAReferencedServerInheritsThatServersKey() throws {
        let bastion = server("bastion", "b", credential: otherKey,
                             via: [.inline(InlineJumpHost(host: "edge", username: "e"))])
        let db = server("db", "db", credential: key, via: [.server(bastion.id)])
        let hops = try JumpChain.hops(to: db, in: [bastion, db], inheritable: [key, otherKey])
        #expect(hops.map(\.credentialID) == [otherKey, otherKey, key])
    }

    @Test func vaultInheritsKeysButNotPasswords() throws {
        let pass = Credential(label: "pw", kind: .password("secret"))
        let pem = Credential(label: "k", kind: .privateKey(pem: "-----BEGIN OPENSSH PRIVATE KEY-----", passphrase: nil))
        let byPassword = server("a", "a", credential: pass.id, via: [.inline(InlineJumpHost(host: "gw", username: "u"))])
        let byKey = server("b", "b", credential: pem.id, via: [.inline(InlineJumpHost(host: "gw", username: "u"))])
        let vault = Vault(servers: [byPassword, byKey], credentials: [pass, pem])
        #expect(try vault.connectionHops(to: byPassword)[0].credentialID == nil)
        #expect(try vault.connectionHops(to: byKey)[0].credentialID == pem.id)
    }

    @Test func referencedServersBringTheirOwnChain() throws {
        let edge = server("edge", "edge.example.com")
        let inner = server("inner", "inner.lan", via: [.server(edge.id)])
        let db = server("db", "db.lan", via: [.server(inner.id)])
        let hops = try JumpChain.hops(to: db, in: [edge, inner, db])
        #expect(hops.map(\.name) == ["edge", "inner", "db"])
    }

    @Test func selfReferenceIsACycle() {
        let id = UUID()
        var a = server("a", "a")
        a.id = id
        a.jumpHosts = [.server(id)]
        #expect(throws: JumpChainError.cycle(["a", "a"])) { try JumpChain.hops(to: a, in: [a]) }
    }

    @Test func twoServerCycle() {
        var a = server("a", "a")
        var b = server("b", "b")
        a.jumpHosts = [.server(b.id)]
        b.jumpHosts = [.server(a.id)]
        #expect(throws: JumpChainError.cycle(["a", "b", "a"])) { try JumpChain.hops(to: a, in: [a, b]) }
        let error = JumpChainError.cycle(["a", "b", "a"])
        #expect(error.message.contains("a › b › a"))
    }

    @Test func sameServerTwiceWithoutCycleIsAllowedButStillBounded() throws {
        // A diamond (db via x and y, both via edge) is no cycle, but it crosses edge twice.
        let edge = server("edge", "edge")
        let x = server("x", "x", via: [.server(edge.id)])
        let y = server("y", "y", via: [.server(edge.id)])
        let db = server("db", "db", via: [.server(x.id), .server(y.id)])
        let hops = try JumpChain.hops(to: db, in: [edge, x, y, db])
        #expect(hops.map(\.name) == ["edge", "x", "edge", "y", "db"])
    }

    @Test func tooDeep() {
        let inline = (1...6).map { JumpHost.inline(InlineJumpHost(host: "h\($0)", username: "u")) }
        let db = server("db", "db", via: inline)
        #expect(throws: JumpChainError.tooDeep(max: JumpChain.maxHops)) { try JumpChain.hops(to: db, in: [db]) }
        let five = server("db", "db", via: Array(inline.prefix(5)))
        #expect((try? JumpChain.hops(to: five, in: [five]))?.count == 6)
    }

    @Test func tooDeepThroughReferences() {
        var chain: [Server] = [server("s0", "s0")]
        for i in 1...6 { chain.append(server("s\(i)", "s\(i)", via: [.server(chain[i - 1].id)])) }
        #expect(throws: JumpChainError.tooDeep(max: 5)) { try JumpChain.hops(to: chain[6], in: chain) }
    }

    @Test func missingServer() {
        let gone = UUID()
        let db = server("db", "db", via: [.server(gone)])
        #expect(throws: JumpChainError.missingServer(gone)) { try JumpChain.hops(to: db, in: [db]) }
        #expect(JumpChainError.missingServer(gone).message.contains("no longer"))
    }

    @Test func summaryNamesTheHops() {
        let bastion = server("bastion", "b")
        let db = server("db", "db", via: [.server(bastion.id), .inline(InlineJumpHost(host: "gw", username: "ops"))])
        #expect(JumpChain.summary(of: db, in: [bastion, db]) == "via bastion, ops@gw")
        #expect(JumpChain.summary(of: bastion, in: [bastion, db]) == nil)
        let orphan = server("o", "o", via: [.server(UUID())])
        #expect(JumpChain.summary(of: orphan, in: [orphan]) == "via (deleted server)")
    }
}

@Suite struct ProxyJumpTests {
    @Test func parsesTheForms() throws {
        let entries = try ProxyJump.parse("bastion, ops@gw.example.com:2222,[fe80::1]:22,root@[2001:db8::1],ssh://me@h:2200")
        #expect(entries == [
            ProxyJumpEntry(username: nil, host: "bastion", port: nil),
            ProxyJumpEntry(username: "ops", host: "gw.example.com", port: 2222),
            ProxyJumpEntry(username: nil, host: "fe80::1", port: 22),
            ProxyJumpEntry(username: "root", host: "2001:db8::1", port: nil),
            ProxyJumpEntry(username: "me", host: "h", port: 2200),
        ])
    }

    @Test func emptyAndNoneMeanNoJumps() throws {
        #expect(try ProxyJump.parse("") == [])
        #expect(try ProxyJump.parse("  ") == [])
        #expect(try ProxyJump.parse("none") == [])
    }

    @Test(arguments: ["a,,b", "a b", "@h", "u@", "h:0", "h:70000", "h:x", "[::1", "a@b@c", "h#x", "h%z", "-oProxyCommand=x"])
    func rejects(_ text: String) {
        #expect(throws: ProxyJumpError.self) { try ProxyJump.parse(text) }
    }

    @Test func tooManyHops() {
        #expect(throws: ProxyJumpError.tooMany(max: 5)) { try ProxyJump.parse("a,b,c,d,e,f") }
    }

    @Test func formatRoundTrips() throws {
        let text = "bastion,ops@gw.example.com:2222,[fe80::1]:22,root@2001:db8::1"
        #expect(ProxyJump.format(try ProxyJump.parse(text)) == text)
    }

    @Test func entriesBecomeVaultReferencesWhenTheyNameAServer() throws {
        let bastion = Server(name: "Bastion", host: "bastion.example.com", port: 2200, username: "jump")
        let servers = [bastion]
        let key = UUID()
        let jumps = try ProxyJump.jumpHosts(from: "bastion,bastion.example.com,ops@gw:2222,gw2",
                                            servers: servers, defaultUsername: "root", credentialID: key)
        #expect(jumps == [
            .server(bastion.id), // by name, case ignored
            .server(bastion.id), // by host
            .inline(InlineJumpHost(host: "gw", port: 2222, username: "ops", credentialID: key)),
            .inline(InlineJumpHost(host: "gw2", port: 22, username: "root", credentialID: key)),
        ])
        // a user or port that differs from the saved server's is its own inline hop
        let other = try ProxyJump.jumpHosts(from: "admin@bastion.example.com", servers: servers,
                                            defaultUsername: "root", credentialID: nil)
        #expect(other == [.inline(InlineJumpHost(host: "bastion.example.com", username: "admin"))])
    }

    @Test func textForAServerChain() {
        let bastion = Server(name: "bastion", host: "b", username: "u")
        let jumps: [JumpHost] = [.server(bastion.id), .inline(InlineJumpHost(host: "gw", port: 2222, username: "ops"))]
        #expect(ProxyJump.text(for: jumps, servers: [bastion]) == "bastion,ops@gw:2222")
    }
}

@Suite struct VaultJumpEditTests {
    func vault() -> (Vault, Server, Server) {
        let bastion = Server(name: "bastion", host: "b", username: "u")
        var db = Server(name: "db", host: "db", username: "u")
        db.jumpHosts = [.server(bastion.id)]
        var v = Vault()
        v.servers = [bastion, db]
        return (v, bastion, db)
    }

    @Test func updateThatMakesACycleIsRefused() {
        let (v, bastion, db) = vault()
        var looped = bastion
        looped.jumpHosts = [.server(db.id)]
        #expect(throws: VaultEditError.jumpChain(.cycle(["bastion", "db", "bastion"]))) { try v.updatingServer(looped) }
    }

    @Test func addingWithUnknownJumpIsRefused() {
        let (v, _, _) = vault()
        var s = Server(name: "x", host: "x", username: "u")
        let gone = UUID()
        s.jumpHosts = [.server(gone)]
        #expect(throws: VaultEditError.jumpChain(.missingServer(gone))) { try v.addingServer(s) }
    }

    @Test func deletingAJumpHostInUseIsRefused() throws {
        let (v, bastion, db) = vault()
        #expect(throws: VaultEditError.usedAsJumpHost(["db"])) { try v.deletingServers([bastion.id]) }
        #expect(VaultEditError.usedAsJumpHost(["db"]).errorDescription?.contains("db") == true)
        // together with the servers that use it, it goes
        let after = try v.deletingServers([bastion.id, db.id])
        #expect(after.servers.isEmpty)
    }

    @Test func vaultResolvesHops() throws {
        let (v, _, db) = vault()
        #expect(try v.connectionHops(to: db).map(\.name) == ["bastion", "db"])
    }
}

@Suite struct JumpFailureTests {
    @Test func namesTheHop() {
        let failure = SSHFailure.viaJumpHost("bastion", .authenticationFailed)
        #expect(failure.message.hasPrefix("Jump host bastion: "))
        #expect(failure.message.contains(SSHFailure.authenticationFailed.message))
    }

    @Test func aRefusedJumpLoginDoesNotTryTheTargetsNextLogin() {
        #expect(!SSHFailure.viaJumpHost("b", .authenticationFailed).triesNextLogin)
    }

    @Test func reconnectsLikeTheHopsFailure() {
        #expect(SSHFailure.viaJumpHost("b", .timedOut(host: "b")).reconnectsAutomatically)
        #expect(!SSHFailure.viaJumpHost("b", .hostKeyRejectedByUser).reconnectsAutomatically)
    }

    @Test func chainErrorsReadAsFailures() {
        #expect(SSHFailure.jumpChain(.tooDeep(max: 5)).message == JumpChainError.tooDeep(max: 5).message)
        #expect(!SSHFailure.jumpChain(.tooDeep(max: 5)).reconnectsAutomatically)
    }
}

@Suite struct QuickConnectViaTests {
    @Test func viaIsParsedAgainstTheVault() throws {
        let bastion = Server(name: "bastion", host: "b.example.com", username: "jump")
        var flow = QuickConnectFlow()
        flow.addHosts("root@10.0.0.5")
        #expect(flow.viaProblem == nil)
        #expect(try flow.jumpHosts(servers: [bastion], defaultUsername: "root", credentialID: nil) == [])
        flow.via = "bastion, ops@gw:2222"
        #expect(flow.viaProblem == nil)
        let jumps = try flow.jumpHosts(servers: [bastion], defaultUsername: "root", credentialID: nil)
        #expect(jumps == [.server(bastion.id), .inline(InlineJumpHost(host: "gw", port: 2222, username: "ops"))])
        flow.via = "a b"
        #expect(flow.viaProblem == ProxyJumpError.invalidEntry("a b").message)
    }

    @Test func savedServersKeepTheJumps() throws {
        var flow = QuickConnectFlow()
        flow.addHosts("root@10.0.0.5")
        let jumps: [JumpHost] = [.inline(InlineJumpHost(host: "gw", username: "ops"))]
        let drafts = try flow.serverDrafts(groupID: nil, credentialID: nil, jumpHosts: jumps)
        #expect(drafts.first?.jumpHosts == jumps)
    }
}
