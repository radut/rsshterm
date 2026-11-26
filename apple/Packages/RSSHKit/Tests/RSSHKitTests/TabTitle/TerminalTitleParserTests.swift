import Testing
@testable import RSSHKit

@Suite struct TerminalTitleParserTests {
    @Test func promptTitles() {
        #expect(TerminalTitleParser.parse("root@sv1: ~/src") == .prompt(user: "root", host: "sv1", cwd: "~/src"))
        #expect(TerminalTitleParser.parse("u@h:/var/log") == .prompt(user: "u", host: "h", cwd: "/var/log"))
    }

    @Test func commandTitlesFromShellIntegration() {
        #expect(TerminalTitleParser.parse("root@sv1 › vim /etc/hosts")
                == .running(user: "root", host: "sv1", commandLine: "vim /etc/hosts"))
    }

    @Test func otherTitlesAreOpaque() {
        #expect(TerminalTitleParser.parse("htop") == nil)
        #expect(TerminalTitleParser.parse("nginx.conf (/etc/nginx) - VIM") == nil)
        #expect(TerminalTitleParser.parse("mail me@example.com now") == nil)
    }

    @Test func osc7() {
        #expect(TerminalTitleParser.parseDirectoryURI("file://sv1/home/u/my%20dir")
                == DirectoryReport(host: "sv1", path: "/home/u/my dir"))
        #expect(TerminalTitleParser.parseDirectoryURI("file:///tmp") == DirectoryReport(host: nil, path: "/tmp"))
        #expect(TerminalTitleParser.parseDirectoryURI("http://x/y") == nil)
    }

    @Test func shellWords() {
        #expect(ShellWords.split("vim 'a b' \"c d\" e\\ f") == ["vim", "a b", "c d", "e f"])
        #expect(ShellWords.split("  ") == [])
    }

    @Test func commandFacts() {
        let cmd = CommandFacts(commandLine: "sudo FOO=1 tail -f /var/log/syslog")
        #expect(cmd.process == "sudo")
        #expect(cmd.args == ["FOO=1", "tail", "-f", "/var/log/syslog"])
        let env = CommandFacts(commandLine: "LANG=C make -j8")
        #expect(env.process == "make")
        #expect(env.args == ["-j8"])
        #expect(CommandFacts(argv: ["-zsh"]).process == "zsh")
        #expect(CommandFacts(argv: ["/usr/bin/vim", "x"]).process == "vim")
    }
}
