import Foundation
import RSSHDesktopCore
import RSSHKit
import Testing
@testable import RSSHTermLinux

@Suite struct SpawnPlannerTests {
    let server = Server(name: "Backup NAS", host: "nas.example.com", username: "admin")
    var env: [String: String] { ["HOME": "/home/u", "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh", "SSH_AUTH_SOCK": "/old"] }

    private func planner(include: Bool) -> SpawnPlanner {
        SpawnPlanner(environment: env, agentSocket: "/run/user/1/rssh/agent.sock", appVersion: "1.0.0",
                     sshConfigPath: "/home/u/.config/rssh/ssh_config", includeInstalled: include)
    }

    @Test func localShellIsALoginShellWithTheAgent() throws {
        let plan = try planner(include: false).plan(.localShell(), servers: []).get()
        #expect(plan.executable == "/bin/sh")
        #expect(plan.argv == ["-sh"])
        #expect(plan.directory == "/home/u")
        #expect(plan.environment["SSH_AUTH_SOCK"] == "/run/user/1/rssh/agent.sock")
        #expect(plan.environment["TERM_PROGRAM"] == "rSshTerm")
        #expect(plan.environment["TERM"] == "xterm-256color")
    }

    @Test func localCommandRunsInItsDirectory() throws {
        let plan = try planner(include: false).plan(.localShell(command: ["sh", "-c", "true"], directory: "/tmp"),
                                                    servers: []).get()
        #expect(plan.executable == "/usr/bin/sh" || plan.executable == "/bin/sh")
        #expect(plan.argv == ["sh", "-c", "true"])
        #expect(plan.directory == "/tmp")
    }

    @Test func sshUsesTheAliasThroughTheIncludeWhenInstalled() throws {
        let plan = try planner(include: true).plan(.ssh(serverID: server.id), servers: [server]).get()
        #expect(plan.argv == ["ssh", "backup-nas"])
        #expect(plan.title == "Backup NAS")
    }

    @Test func sshNamesTheGeneratedConfigWithoutTheInclude() throws {
        let plan = try planner(include: false).plan(.ssh(serverID: server.id), servers: [server]).get()
        #expect(plan.argv == ["ssh", "-F", "/home/u/.config/rssh/ssh_config", "backup-nas"])
    }

    @Test func anotherLoginGoesBeforeTheAlias() throws {
        let override = SSHLoginOverride(username: "ubuntu", login: .askPassword, markerFile: "/run/m")
        let plan = try planner(include: false).plan(.ssh(serverID: server.id), servers: [server], override: override).get()
        #expect(plan.argv == ["ssh", "-F", "/home/u/.config/rssh/ssh_config"] + override.arguments + ["backup-nas"])
        #expect(plan.title == "Backup NAS")
    }

    @Test func unknownServerIsAnError() {
        let result = planner(include: true).plan(.ssh(serverID: UUID()), servers: [server])
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error == .unknownServer)
    }

    @Test func serverWithUnsafeHostHasNoAlias() {
        let bad = Server(name: "bad", host: "a b", username: "x")
        let result = planner(include: true).plan(.ssh(serverID: bad.id), servers: [bad])
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error == .notInSSHConfig("bad"))
    }
}
