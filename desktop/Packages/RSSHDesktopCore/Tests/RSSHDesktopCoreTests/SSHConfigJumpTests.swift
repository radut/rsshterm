import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@Suite struct SSHConfigJumpTests {
    let bastionKey = UUID()
    let dbKey = UUID()
    let gwKey = UUID()

    var keys: [SSHConfigKey] {
        [SSHConfigKey(credentialID: bastionKey, publicLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl b"),
         SSHConfigKey(credentialID: dbKey, publicLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBX3XwMXg6Ww4sY4N2pRxMmY7b0d6bLUtTnKp7pEnoaq d"),
         SSHConfigKey(credentialID: gwKey, publicLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBX3XwMXg6Ww4sY4N2pRxMmY7b0d6bLUtTnKp7pEnoab g")]
    }

    struct Fixture {
        var bastion: Server
        var db: Server
        var all: [Server]
    }

    func fixture() -> Fixture {
        let bastion = Server(name: "Bastion", host: "bastion.example.com", port: 2200, username: "jump", credentialID: bastionKey)
        var db = Server(name: "db", host: "10.0.0.5", username: "postgres", credentialID: dbKey)
        db.jumpHosts = [.server(bastion.id), .inline(InlineJumpHost(host: "gw.internal", port: 2222, username: "ops", credentialID: gwKey))]
        var direct = Server(name: "inner", host: "inner.lan", username: "u")
        direct.jumpHosts = [.inline(InlineJumpHost(host: "fe80::1", username: "root"))] // no key: the target's login
        var orphan = Server(name: "orphan", host: "o.lan", username: "u")
        orphan.jumpHosts = [.server(UUID())]
        var unsafe = Server(name: "via-unsafe", host: "x.lan", username: "u")
        unsafe.jumpHosts = [.inline(InlineJumpHost(host: "gw,evil", username: "u"))]
        let evil = Server(name: "evil", host: "e.example.com\n  ProxyCommand sh", username: "root")
        var viaEvil = Server(name: "via-evil", host: "v.lan", username: "u")
        viaEvil.jumpHosts = [.server(evil.id)]
        return Fixture(bastion: bastion, db: db, all: [bastion, db, direct, orphan, unsafe, evil, viaEvil])
    }

    func generate(_ servers: [Server]) -> SSHConfigFiles {
        SSHConfigGenerator.generate(servers: servers, keys: keys, agentSocket: "/run/a.sock", keyDirectory: "/k")
    }

    func block(_ files: SSHConfigFiles, _ alias: String) -> String? {
        // The header has no blank line after it, so the first block starts after its last line.
        files.config.dropFirst(SSHConfigGenerator.header.count).components(separatedBy: "\n\n")
            .first { $0.hasPrefix("Host \(alias)\n") || $0.hasPrefix("Host \(alias) ") }
    }

    @Test func proxyJumpUsesAliasesAndInlineBlocks() throws {
        let files = generate(fixture().all)
        let db = try #require(block(files, "db"))
        #expect(db.contains("    ProxyJump bastion,db-jump-2\n") || db.hasSuffix("    ProxyJump bastion,db-jump-2"))
        // the inline hop gets its own block so it logs in with the vault agent and its key
        let hop = try #require(block(files, "db-jump-2"))
        #expect(hop.contains("    HostName gw.internal\n    User ops\n    Port 2222\n    IdentityAgent \"/run/a.sock\""))
        #expect(hop.contains("IdentityFile \"/k/\(gwKey.uuidString.lowercased()).pub\""))
        #expect(files.publicKeys["\(gwKey.uuidString.lowercased()).pub"] != nil)
        // the bastion block itself has no ProxyJump
        #expect(block(files, "bastion")?.contains("ProxyJump") == false)
    }

    @Test func inlineHopWithoutKeyUsesTheTargetsKeyAndIPv6IsPlain() throws {
        let files = generate(fixture().all)
        let inner = try #require(block(files, "inner"))
        #expect(inner.contains("ProxyJump inner-jump-1"))
        let hop = try #require(block(files, "inner-jump-1"))
        #expect(hop.contains("HostName fe80::1\n    User root\n    Port 22"))
        #expect(!hop.contains("IdentityFile")) // the target logs in with a password: nothing to pin
    }

    @Test func brokenChainsAreSkipped() {
        let files = generate(fixture().all)
        #expect(files.skipped["orphan"] == "jump host")
        #expect(files.skipped["via-unsafe"] == "jump host")
        #expect(files.skipped["evil"] == "host")
        #expect(files.skipped["via-evil"] == "jump host")
        #expect(!files.config.contains("evil"))
    }

    @Test func cyclesAreSkipped() {
        var a = Server(name: "a", host: "a.lan", username: "u")
        var b = Server(name: "b", host: "b.lan", username: "u")
        a.jumpHosts = [.server(b.id)]
        b.jumpHosts = [.server(a.id)]
        let files = generate([a, b])
        #expect(files.skipped == ["a": "jump host", "b": "jump host"])
    }

    /// The desktop apps search and type `ssh <alias>` from `aliases(for:)`: exactly the server blocks the file has.
    @Test func aliasesAreExactlyTheWrittenServers() throws {
        var all = fixture().all
        var a = Server(name: "a", host: "a.lan", username: "u")
        var b = Server(name: "b", host: "b.lan", username: "u")
        a.jumpHosts = [.server(b.id)]
        b.jumpHosts = [.server(a.id)]
        // a server named like an inline hop block gets another alias than that block
        let clash = Server(name: "db-jump-2", host: "c.lan", username: "u")
        all += [a, b, clash]
        let aliases = SSHConfigGenerator.aliases(for: all)
        let byName = Dictionary(all.map { ($0.name, $0.id) }) { first, _ in first }
        for skipped in ["orphan", "via-unsafe", "evil", "via-evil", "a", "b"] {
            #expect(aliases[byName[skipped]!] == nil, "\(skipped)")
        }
        #expect(aliases[byName["db"]!] == "db")
        #expect(aliases[byName["Bastion"]!] == "bastion")
        let files = generate(all)
        let hostLines = files.config.split(separator: "\n").filter { $0.hasPrefix("Host ") }
            .map { String($0.dropFirst(5).split(separator: " ")[0]) }
        // every written block is a server alias or an inline hop block, never both
        let hopBlocks = Set(hostLines).subtracting(aliases.values)
        #expect(Set(aliases.values).isSubset(of: Set(hostLines)))
        #expect(hopBlocks.allSatisfy { $0.contains("-jump-") })
        #expect(hostLines.count == Set(hostLines).count) // no alias written twice
        #expect(aliases[byName["db-jump-2"]!] == "db-jump-2")
        #expect(try #require(block(files, "db")).contains("ProxyJump bastion,db-jump-2-2"))
    }

    @Test func noJumpsNoProxyJump() {
        let files = generate([fixture().bastion])
        #expect(!files.config.contains("ProxyJump"))
    }

    /// `ssh -G` reads the chain the way we mean it: the target names the jump aliases, which resolve on their own.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")))
    func openSSHReadsTheChain() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let writer = SSHConfigWriter(directory: "\(dir.path)/rssh")
        try writer.write(SSHConfigGenerator.generate(servers: fixture().all, keys: keys,
                                                     agentSocket: "\(dir.path)/agent.sock", keyDirectory: writer.keyDirectory))
        let env = ["HOME": dir.path, "PATH": "/usr/bin:/bin"]
        let (status, db) = try run("/usr/bin/ssh", ["-G", "-F", writer.configPath, "db"], environment: env)
        #expect(status == 0, "\(db)")
        let lines = Set(db.split(separator: "\n").map(String.init))
        #expect(lines.contains("proxyjump bastion,db-jump-2"))
        #expect(lines.contains("hostname 10.0.0.5"))
        let (_, hop) = try run("/usr/bin/ssh", ["-G", "-F", writer.configPath, "db-jump-2"], environment: env)
        let hopLines = Set(hop.split(separator: "\n").map(String.init))
        #expect(hopLines.contains("hostname gw.internal"))
        #expect(hopLines.contains("user ops"))
        #expect(hopLines.contains("port 2222"))
        #expect(hopLines.contains("identityfile \(writer.keyDirectory)/\(gwKey.uuidString.lowercased()).pub"))
        let (_, bastion) = try run("/usr/bin/ssh", ["-G", "-F", writer.configPath, "bastion"], environment: env)
        #expect(bastion.contains("port 2200") && bastion.contains("user jump"))
        #expect(!bastion.contains("proxyjump"))
    }
}
