import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite struct SSHConfigTests {
    let webKey = UUID()
    let dbKey = UUID()
    var keys: [SSHConfigKey] {
        [SSHConfigKey(credentialID: webKey, publicLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl web"),
         SSHConfigKey(credentialID: dbKey, publicLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBX3XwMXg6Ww4sY4N2pRxMmY7b0d6bLUtTnKp7pEnoaq db")]
    }
    var servers: [Server] {
        [
            Server(name: "Web Prod 1", host: "web1.example.com", username: "deploy", credentialID: webKey),
            Server(name: "db", host: "203.0.113.5", port: 2222, username: "postgres", credentialID: dbKey),
            Server(name: "web prod 1", host: "web9.example.com", username: "deploy"), // alias clash, password login
            Server(name: "shared-a", host: "shared.example.com", username: "a"),
            Server(name: "shared-b", host: "shared.example.com", username: "b"),
            Server(name: "evil", host: "x.example.com\n  ProxyCommand sh", username: "root"),
            Server(name: "evil2", host: "y.example.com", username: "root #"),
        ]
    }

    private func generate(socket: String = "/run/user/1000/rssh/agent.sock", keyDir: String = "/home/u/.config/rssh/keys")
        -> SSHConfigFiles {
        SSHConfigGenerator.generate(servers: servers, keys: keys, agentSocket: socket, keyDirectory: keyDir)
    }

    @Test func aliasesMatchTheGeneratedHostBlocks() {
        let list = servers // computed: new ids on every read
        let aliases = SSHConfigGenerator.aliases(for: list)
        let byName = Dictionary(list.map { ($0.name, $0.id) }) { a, _ in a }
        #expect(aliases[byName["Web Prod 1"]!] == "web-prod-1")
        #expect(aliases[byName["web prod 1"]!] == "web-prod-1-2")
        #expect(aliases[byName["db"]!] == "db")
        #expect(aliases[byName["evil"]!] == nil) // skipped: unsafe host
        let config = SSHConfigGenerator.generate(servers: list, keys: keys, agentSocket: "/s", keyDirectory: "/k").config
        for alias in aliases.values { #expect(config.contains("Host \(alias)")) }
    }

    @Test func entries() {
        let files = generate()
        #expect(files.config.hasPrefix(SSHConfigGenerator.header))
        #expect(files.config.contains("""
        Host web-prod-1 web1.example.com
            HostName web1.example.com
            User deploy
            Port 22
            IdentityAgent "/run/user/1000/rssh/agent.sock"
            IdentityFile "/home/u/.config/rssh/keys/\(webKey.uuidString.lowercased()).pub"
            IdentitiesOnly yes
        """))
        #expect(files.config.contains("Host db 203.0.113.5\n    HostName 203.0.113.5\n    User postgres\n    Port 2222"))
        let passwordBlock = files.config.components(separatedBy: "\n\n").first { $0.hasPrefix("Host web-prod-1-2 ") }
        #expect(passwordBlock?.hasPrefix("Host web-prod-1-2 web9.example.com\n    HostName web9.example.com\n    User deploy") == true)
        #expect(passwordBlock?.contains("IdentityFile") == false) // password login: no key pinned
        // two servers on one host: only their aliases, so `ssh shared.example.com` stays ambiguous-free
        #expect(files.config.contains("Host shared-a\n"))
        #expect(files.config.contains("Host shared-b\n"))
        #expect(files.publicKeys["\(webKey.uuidString.lowercased()).pub"] == keys[0].publicLine + "\n")
        #expect(files.publicKeys.count == 2)
    }

    @Test func unsafeValuesAreSkipped() {
        let files = generate()
        #expect(files.skipped == ["evil": "host", "evil2": "user"])
        #expect(!files.config.contains("ProxyCommand"))
    }

    @Test func percentAndSpacesInPathsAreQuoted() {
        let files = generate(socket: "/Users/u/Library/Application Support/rSshTerm/agent.sock", keyDir: "/tmp/100%/keys")
        #expect(files.config.contains("IdentityAgent \"/Users/u/Library/Application Support/rSshTerm/agent.sock\""))
        #expect(files.config.contains("IdentityFile \"/tmp/100%%/keys/"))
    }

    @Test func aliases() {
        #expect(SSHConfigGenerator.alias(for: "Backup NAS") == "backup-nas")
        #expect(SSHConfigGenerator.alias(for: "  web/prod (eu)  ") == "web-prod-eu")
        #expect(SSHConfigGenerator.alias(for: "pi-hole.lan") == "pi-hole.lan")
    }

    @Test func writerPermissionsAndStaleKeys() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let writer = SSHConfigWriter(directory: "\(dir.path)/rssh")
        try FileManager.default.createDirectory(atPath: writer.keyDirectory, withIntermediateDirectories: true)
        try "old".write(toFile: "\(writer.keyDirectory)/gone.pub", atomically: true, encoding: .utf8)
        try writer.write(generate(keyDir: writer.keyDirectory))
        var info = stat()
        #expect(stat(writer.directory, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(stat(writer.configPath, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let pubs = try FileManager.default.contentsOfDirectory(atPath: writer.keyDirectory).sorted()
        #expect(pubs == [webKey, dbKey].map { "\($0.uuidString.lowercased()).pub" }.sorted())
        try writer.write(generate(keyDir: writer.keyDirectory)) // rewriting works
    }

    @Test func defaultDirectory() {
        #expect(SSHConfigWriter.defaultDirectory(environment: [:], home: "/home/u") == "/home/u/.config/rssh")
        #expect(SSHConfigWriter.defaultDirectory(environment: ["XDG_CONFIG_HOME": "/x"], home: "/home/u") == "/x/rssh")
    }

    /// OpenSSH resolves the generated file the way we mean it: `ssh -G` prints the effective options.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")))
    func openSSHReadsIt() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let writer = SSHConfigWriter(directory: "\(dir.path)/rssh")
        let files = generate(socket: "\(dir.path)/agent dir/agent.sock", keyDir: writer.keyDirectory)
        try writer.write(files)
        let env = ["HOME": dir.path, "PATH": "/usr/bin:/bin"]
        let (status, output) = try run("/usr/bin/ssh", ["-G", "-F", writer.configPath, "web-prod-1"], environment: env)
        #expect(status == 0, "\(output)")
        let lines = Set(output.split(separator: "\n").map(String.init))
        #expect(lines.contains("hostname web1.example.com"))
        #expect(lines.contains("user deploy"))
        #expect(lines.contains("port 22"))
        #expect(lines.contains("identitiesonly yes"))
        #expect(lines.contains("identityagent \"\(dir.path)/agent dir/agent.sock\"") || lines.contains("identityagent \(dir.path)/agent dir/agent.sock"))
        #expect(lines.contains("identityfile \(writer.keyDirectory)/\(webKey.uuidString.lowercased()).pub"))
        // by real host name too
        let (_, byHost) = try run("/usr/bin/ssh", ["-G", "-F", writer.configPath, "203.0.113.5"], environment: env)
        #expect(byHost.contains("port 2222") && byHost.contains("user postgres"))
    }
}
