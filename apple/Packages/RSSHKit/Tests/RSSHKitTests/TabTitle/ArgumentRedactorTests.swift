import Testing
@testable import RSSHKit

@Suite struct ArgumentRedactorTests {
    let mask = ArgumentRedactor.mask

    @Test func passwordFlagsWithSeparateValue() {
        #expect(ArgumentRedactor.redact(program: "tool", ["--password", "x1", "f"]) == ["--password", mask, "f"])
        #expect(ArgumentRedactor.redact(program: "tool", ["--token", "abc"]) == ["--token", mask])
        #expect(ArgumentRedactor.redact(program: "tool", ["--api-key", "k", "--client-secret", "s"])
                == ["--api-key", mask, "--client-secret", mask])
        #expect(ArgumentRedactor.redact(program: "tool", ["-password", "p"]) == ["-password", mask])
    }

    @Test func passwordFlagsWithEquals() {
        #expect(ArgumentRedactor.redact(program: "tool", ["--password=x1"]) == ["--password=" + mask])
        #expect(ArgumentRedactor.redact(program: "tool", ["--auth-token=abc", "--verbose"])
                == ["--auth-token=" + mask, "--verbose"])
    }

    @Test func shortPIsProgramSpecific() {
        #expect(ArgumentRedactor.redact(program: "ssh", ["-p", "2222", "root@sv1"]) == ["-p", "2222", "root@sv1"])
        #expect(ArgumentRedactor.redact(program: "mysql", ["-u", "root", "-psecret"]) == ["-u", "root", "-p" + mask])
        #expect(ArgumentRedactor.redact(program: "mysql", ["-p"]) == ["-p"])
        #expect(ArgumentRedactor.redact(program: "sshpass", ["-p", "pw", "ssh", "h"]) == ["-p", mask, "ssh", "h"])
        #expect(ArgumentRedactor.redact(program: "/usr/bin/sshpass", ["-ppw", "ssh"]) == ["-p" + mask, "ssh"])
    }

    @Test func secretLookingAssignmentsAndURLs() {
        #expect(ArgumentRedactor.redact(program: "env", ["GITHUB_TOKEN=ghp_x", "PATH=/bin", "make"])
                == ["GITHUB_TOKEN=" + mask, "PATH=/bin", "make"])
        #expect(ArgumentRedactor.redact(program: "git", ["clone", "https://u:pw@example.com/r.git"])
                == ["clone", "https://u:\(mask)@example.com/r.git"])
        #expect(ArgumentRedactor.redact(program: "curl", ["-H", "Authorization: Bearer abc.def", "https://x"])
                == ["-H", "Authorization: " + mask, "https://x"])
        #expect(ArgumentRedactor.redact(program: "curl", ["-u", "admin:pw", "-H", "X-Api-Key: k1", "--user=a:b"])
                == ["-u", "admin:" + mask, "-H", "X-Api-Key: " + mask, "--user=a:" + mask])
    }

    @Test func wrappersPassTheRulesOn() {
        #expect(ArgumentRedactor.redact(program: "sudo", ["mysql", "-psecret"]) == ["mysql", "-p" + mask])
        #expect(ArgumentRedactor.redact(program: "sudo", ["-u", "root", "env", "API_TOKEN=x", "sshpass", "-p", "pw", "ssh", "h"])
                == ["-u", "root", "env", "API_TOKEN=" + mask, "sshpass", "-p", mask, "ssh", "h"])
        #expect(ArgumentRedactor.redact(program: "time", ["tool", "--password", "x"]) == ["tool", "--password", mask])
    }

    @Test func goAndSwiftAgree() {
        // The same table as rsshd/internal/probe/pane_test.go TestSanitizeArgs.
        #expect(ArgumentRedactor.redact(program: "tool", ["--key-file", "/k"]) == ["--key-file", "/k"])
        #expect(ArgumentRedactor.redact(program: "mysql", ["-u", "root", "-psecret", "-p"]) == ["-u", "root", "-p" + mask, "-p"])
    }

    @Test func plainArgumentsPass() {
        let args = ["-f", "/var/log/syslog", "--lines=50"]
        #expect(ArgumentRedactor.redact(program: "tail", args) == args)
    }
}
