import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

/// The command line of a default terminal, and what an ssh:// URL opens.
@Suite struct TerminalArgumentsTests {
    @Test func noArgumentsIsAPlainLaunch() throws {
        let args = try TerminalArguments.parse([])
        #expect(args.isEmpty)
        #expect(args.localContent == nil)
    }

    @Test func executeTakesTheRestAsArgv() throws {
        let args = try TerminalArguments.parse(["-e", "htop", "-d", "10"])
        #expect(args.command == ["htop", "-d", "10"])
        #expect(args.localContent == .localShell(command: ["htop", "-d", "10"], directory: nil))
    }

    @Test(arguments: ["-x", "--", "--execute"])
    func executeSpellings(_ flag: String) throws {
        #expect(try TerminalArguments.parse([flag, "top"]).command == ["top"])
    }

    @Test func oneWordWithSpacesRunsThroughTheShell() throws {
        #expect(try TerminalArguments.parse(["-e", "vim notes.txt"]).command == ["/bin/sh", "-c", "vim notes.txt"])
    }

    @Test func workingDirectoryBothSpellings() throws {
        #expect(try TerminalArguments.parse(["--working-directory", "/srv/app"]).directory == "/srv/app")
        let joined = try TerminalArguments.parse(["--working-directory=/srv/my app", "-e", "ls"])
        #expect(joined.localContent == .localShell(command: ["ls"], directory: "/srv/my app"))
    }

    @Test func directoryAloneIsALocalShellThere() throws {
        #expect(try TerminalArguments.parse(["--working-directory", "/tmp"]).localContent == .localShell(directory: "/tmp"))
    }

    @Test func titleIsKept() throws {
        let args = try TerminalArguments.parse(["-T", "logs", "-e", "tail", "-f", "/var/log/syslog"])
        #expect(args.title == "logs")
        #expect(args.command == ["tail", "-f", "/var/log/syslog"])
    }

    @Test func sshURLArgument() throws {
        let args = try TerminalArguments.parse(["ssh://deploy@build.example.org:2222"])
        #expect(args.url == SSHURL(username: "deploy", host: "build.example.org", port: 2222))
        #expect(args.localContent == nil)
    }

    @Test func errors() {
        #expect(throws: TerminalArgumentError.missingValue("-e")) { try TerminalArguments.parse(["-e"]) }
        #expect(throws: TerminalArgumentError.missingValue("--working-directory")) {
            try TerminalArguments.parse(["--working-directory"])
        }
        #expect(throws: TerminalArgumentError.unknown("--frobnicate")) { try TerminalArguments.parse(["--frobnicate"]) }
        #expect(throws: TerminalArgumentError.badURL("ssh://")) { try TerminalArguments.parse(["ssh://"]) }
    }

    // MARK: ssh:// URLs

    @Test func urlForms() {
        #expect(SSHURL("ssh://host.example") == SSHURL(username: nil, host: "host.example", port: nil))
        #expect(SSHURL("SSH://root@10.0.0.7/") == SSHURL(username: "root", host: "10.0.0.7", port: nil))
        #expect(SSHURL("ssh://u;fingerprint=ssh-ed25519-abc@h:22") == SSHURL(username: "u", host: "h", port: 22))
        #expect(SSHURL("ssh://me@[fe80::1]:2200") == SSHURL(username: "me", host: "fe80::1", port: 2200))
        #expect(SSHURL("ssh://first%2Elast@h") == SSHURL(username: "first.last", host: "h", port: nil))
        #expect(SSHURL("ssh://first%20last@h") == nil) // no spaces in a user name
    }

    @Test(arguments: ["http://h", "ssh://", "ssh://@h", "ssh://u@", "ssh://h:0", "ssh://h:99999", "ssh://h:x",
                      "ssh://a:b:c", "ssh://[::1", "ssh://h h"])
    func badURLs(_ text: String) {
        #expect(SSHURL(text) == nil)
    }

    @Test func aMatchingSavedServerOpens() {
        let web = Server(name: "web", host: "web.example.org", username: "deploy")
        let other = Server(name: "other", host: "web.example.org", port: 2222, username: "deploy")
        #expect(SSHURL("ssh://deploy@WEB.example.org")!.opening(in: [other, web]) == .server(web.id))
        #expect(SSHURL("ssh://web.example.org:2222")!.opening(in: [web, other]) == .server(other.id))
    }

    @Test func noSavedServerGoesToQuickConnect() {
        let web = Server(name: "web", host: "web.example.org", username: "deploy")
        #expect(SSHURL("ssh://root@web.example.org")!.opening(in: [web])
                    == .quickConnect(QuickAddress(username: "root", host: "web.example.org", port: nil)))
    }

    @Test func noUserAndNoServerRunsSSHInALocalTab() {
        #expect(SSHURL("ssh://lab.example.org:2200")!.opening(in: []) == .command(["ssh", "-p", "2200", "--", "lab.example.org"]))
        #expect(SSHURL("ssh://lab.example.org")!.opening(in: []) == .command(["ssh", "--", "lab.example.org"]))
    }
}
