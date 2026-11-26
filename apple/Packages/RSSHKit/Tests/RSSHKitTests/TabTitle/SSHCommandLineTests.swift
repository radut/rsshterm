import Testing
@testable import RSSHKit

@Suite struct SSHCommandLineTests {
    @Test func userAtHost() {
        #expect(SSHCommandLine.parse(["ssh", "root@sv1"]) == SSHCommandLine(user: "root", destination: "sv1"))
    }

    @Test func loginFlagPortAndOptions() {
        let parsed = SSHCommandLine.parse(["/usr/bin/ssh", "-A", "-p", "2222", "-l", "admin", "-i", "~/.ssh/k",
                                           "-o", "StrictHostKeyChecking=no", "web1.example.com"])
        #expect(parsed == SSHCommandLine(user: "admin", destination: "web1.example.com", port: 2222))
    }

    @Test func attachedOptionValues() {
        #expect(SSHCommandLine.parse(["ssh", "-p2222", "-lroot", "sv1"])
                == SSHCommandLine(user: "root", destination: "sv1", port: 2222))
        #expect(SSHCommandLine.parse(["ssh", "-oUser=deploy", "sv1"])
                == SSHCommandLine(user: "deploy", destination: "sv1"))
        #expect(SSHCommandLine.parse(["ssh", "-o", "Port=2200", "sv1"])
                == SSHCommandLine(destination: "sv1", port: 2200))
    }

    @Test func remoteCommandAfterDestination() {
        let parsed = SSHCommandLine.parse(["ssh", "-t", "u@h", "htop", "-d", "5"])
        #expect(parsed?.destination == "h")
        #expect(parsed?.remoteCommand == ["htop", "-d", "5"])
    }

    @Test func sshURLAndBundledFlags() {
        #expect(SSHCommandLine.parse(["ssh", "ssh://ops@db1:2201"])
                == SSHCommandLine(user: "ops", destination: "db1", port: 2201))
        #expect(SSHCommandLine.parse(["ssh", "-tAv", "sv1"]) == SSHCommandLine(destination: "sv1"))
        #expect(SSHCommandLine.parse(["ssh", "-J", "jump", "u@[fe80::1]"])
                == SSHCommandLine(user: "u", destination: "fe80::1"))
    }

    @Test func moshAndAutossh() {
        #expect(SSHCommandLine.parse(["mosh", "root@sv1"])?.destination == "sv1")
        #expect(SSHCommandLine.parse(["autossh", "-M", "0", "u@h"]) == SSHCommandLine(user: "u", destination: "h"))
    }

    @Test(arguments: [["ssh"], ["ssh", "-V"], ["vim", "root@sv1"], [], ["ssh", "-p"]])
    func notAConnection(_ argv: [String]) {
        #expect(SSHCommandLine.parse(argv) == nil)
    }

    @Test func resolvesAliasesAgainstConfigAndVault() {
        let config = SSHConfigHosts(text: """
        Host web
          HostName web1.example.com
          User deploy
          Port 2200
        Host *
          User nobody
        """)
        let parsed = SSHCommandLine.parse(["ssh", "web"])!
        let resolved = parsed.resolved(config: config, vault: [:])
        #expect(resolved.alias == "web")
        #expect(resolved.host == "web1.example.com")
        #expect(resolved.user == "deploy")
        #expect(resolved.port == 2200)

        let explicit = SSHCommandLine.parse(["ssh", "root@web"])!.resolved(config: config, vault: [:])
        #expect(explicit.user == "root")

        let vault = ["sv1": VaultHostFacts(name: "Prod API", host: "10.0.0.5", user: "admin", port: 22)]
        let fromVault = SSHCommandLine.parse(["ssh", "sv1"])!.resolved(config: SSHConfigHosts(text: ""), vault: vault)
        #expect(fromVault.server == "Prod API")
        #expect(fromVault.host == "10.0.0.5")
        #expect(fromVault.user == "admin")
        #expect(fromVault.alias == "sv1")
    }

    @Test func configMatchesPatterns() {
        let config = SSHConfigHosts(text: "Host *.lab !bad.lab\n  User labuser\n")
        #expect(config.settings(for: "a.lab").user == "labuser")
        #expect(config.settings(for: "bad.lab").user == nil)
        #expect(config.settings(for: "other").user == nil)
    }
}
