import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@MainActor @Suite struct QuickConnectModelTests {
    @Test func stepsLoginsAndPlans() throws {
        let key = Credential(label: "k", kind: .privateKey(pem: testKeyPEM, passphrase: nil))
        let pw = Credential(label: "pw", kind: .password("x"))
        let doc = TestDocument(Vault(credentials: [pw, key]))
        let quick = QuickConnectModel(document: doc, users: ["root", "ubuntu"])
        #expect(quick.step == .hosts)
        quick.hostsText = "198.51.100.1, admin@198.51.100.2:2222 not/a/host"
        quick.addHosts()
        #expect(quick.hosts.count == 2 && quick.invalidTokens == ["not/a/host"] && quick.hostsText.isEmpty)
        #expect(quick.step == .user)
        quick.chooseUser("root")
        #expect(quick.step == .login)
        #expect(quick.savedLogins.map(\.label) == ["k", "pw"])
        #expect(quick.automaticLogins.map(\.label) == ["k"])

        #expect(quick.connect(with: .password) == nil && quick.error != nil)
        quick.password = "typed"
        let plans = try #require(quick.connect(with: .password))
        #expect(plans.map(\.target.displayName) == ["root@198.51.100.1", "admin@198.51.100.2:2222"])
        #expect(plans[0].logins.first?.secret == .password("typed"))
        #expect(quick.step == .connecting)
        quick.stopConnecting()
        let auto = try #require(quick.connect(with: .automatic))
        #expect(auto[0].logins.map(\.credentialID) == [key.id])
    }

    @Test func savesIntoANewFolderWithThePassword() async throws {
        let existing = Server(name: "old", host: "198.51.100.2", port: 2222, username: "admin")
        let doc = TestDocument(Vault(servers: [existing]))
        let quick = QuickConnectModel(document: doc, address: QuickAddress.parse("root@198.51.100.1"))
        quick.addHosts("admin@198.51.100.2:2222")
        quick.password = "typed"
        let saved = await quick.save(to: .newFolder("Quick"), savePassword: true)
        #expect(saved.map(\.host) == ["198.51.100.1"])
        let folder = try #require(doc.vault.groups.first { $0.name == "Quick" })
        #expect(saved[0].groupID == folder.id)
        #expect(doc.vault.credentials.first { $0.id == saved[0].credentialID }?.kind == .password("typed"))
    }
}

@MainActor @Suite struct QuickConnectServicesTests {
    @Test func savesSSHAndTickedScreens() async throws {
        let doc = TestDocument(Vault())
        let quick = QuickConnectModel(document: doc, address: QuickAddress.parse("admin@win.example.com"))
        #expect(quick.sshEnabled && quick.screens.isEmpty)
        quick.screens = [.rdp]
        quick.sshEnabled = false
        let saved = await quick.save(to: .ungrouped)
        let server = try #require(saved.first)
        #expect(!server.sshEnabled && doc.vault.service(.rdp, of: server.id)?.transport == .direct)
        quick.screens = []
        #expect(await quick.save(to: .ungrouped).isEmpty && quick.error != nil)
    }

    @Test func screensOfASavedHostJoinItOnlyWhenAsked() async throws {
        let nas = Server(name: "nas", host: "nas.example.com", username: "admin")
        let doc = TestDocument(Vault(servers: [nas]))
        let quick = QuickConnectModel(document: doc, address: QuickAddress.parse("admin@nas.example.com"))
        #expect(quick.savedServersForScreens.isEmpty)
        quick.screens = [.vnc]
        #expect(quick.savedServersForScreens.map(\.id) == [nas.id])
        _ = await quick.save(to: .ungrouped, screensJoinSavedServers: true)
        #expect(doc.vault.servers == [nas] && doc.vault.service(.vnc, of: nas.id) != nil)
    }
}

/// A scan answer per host, as the RSSHKit scanner tests use.
private struct ScriptedProbe: PortProbe {
    let open: [String: String]
    func probe(host: String, port: Int, timeout: Duration) async -> ProbeOutcome {
        open[host].map { .open(firstLine: $0) } ?? .closed
    }
}

@MainActor @Suite struct NetworkScanModelTests {
    @Test func scansSelectsAndAdds() async throws {
        let saved = Server(name: "known", host: "192.0.2.3", username: "u")
        let doc = TestDocument(Vault(servers: [saved]))
        let scanner = NetworkScanner(probe: ScriptedProbe(open: ["192.0.2.2": "SSH-2.0-OpenSSH_9.6", "192.0.2.3": "SSH-2.0-x"]))
        let scan = NetworkScanModel(document: doc, scanner: scanner, suggestedRange: "192.0.2.0/29")
        #expect(scan.rangeText == "192.0.2.0/29" && scan.portsText == "22 3389 5900")
        scan.portsText = "22"  // SSH only here; screens have their own test
        scan.start()
        await scan.waitUntilDone()
        #expect(!scan.isScanning && scan.found.map(\.host).sorted() == ["192.0.2.2", "192.0.2.3"])
        #expect(scan.selection == ["192.0.2.2:22"])
        #expect(scan.isSaved(scan.found.first { $0.host == "192.0.2.3" }!))
        let added = await scan.addSelected(username: "deploy", to: .newFolder("192.0.2.0/29"))
        #expect(added == 1 && scan.selection.isEmpty)
        #expect(doc.vault.servers.contains { $0.host == "192.0.2.2" && $0.username == "deploy" })

        scan.rangeText = "not a range"
        scan.start()
        #expect(scan.error != nil && !scan.isScanning)
    }

    @Test func addsWithANewPasswordAndAJumpHost() async throws {
        let bastion = Server(name: "bastion", host: "bastion.example.com", username: "ops")
        let doc = TestDocument(Vault(servers: [bastion]))
        let scanner = NetworkScanner(probe: ScriptedProbe(open: ["192.0.2.2": "SSH-2.0-x", "192.0.2.4": "SSH-2.0-x"]))
        let scan = NetworkScanModel(document: doc, scanner: scanner, suggestedRange: "192.0.2.0/29")
        #expect(scan.jumpCandidates.map(\.name) == ["bastion"])
        scan.start()
        await scan.waitUntilDone()
        #expect(scan.newPasswordLabel(username: "root") == "root@192.0.2.0/29")
        let added = await scan.addSelected(username: "root", login: .newPassword("s3cret", label: "root@192.0.2.0/29"),
                                           jumpHosts: [.server(bastion.id)], to: .ungrouped)
        #expect(added == 2)
        let password = try #require(doc.vault.credentials.first)
        #expect(doc.vault.credentials.count == 1 && password.label == "root@192.0.2.0/29")
        let new = doc.vault.servers.filter { $0.id != bastion.id }
        #expect(new.count == 2 && new.allSatisfy { $0.credentialID == password.id && $0.jumpHosts == [.server(bastion.id)] })
        #expect(scan.savedLogins.map(\.id) == [password.id])
    }

    @Test func addChoicesTurnIntoALoginAndAJumpList() async throws {
        let key = Credential(label: "k", kind: .privateKey(pem: testKeyPEM, passphrase: nil))
        let a = Server(name: "a", host: "a.example.com", username: "ops"), b = Server(name: "b", host: "b.example.com", username: "ops")
        let doc = TestDocument(Vault(servers: [a, b], credentials: [key]))
        let scan = NetworkScanModel(document: doc, scanner: NetworkScanner(probe: ScriptedProbe(open: [:])), suggestedRange: "192.0.2.0/30")
        #expect(scan.discoveredLogin(username: "root") == .none)
        scan.addLogin = .saved(key.id)
        #expect(scan.discoveredLogin(username: "root") == .saved(key.id))
        scan.addLogin = .newPassword
        scan.newPassword = "typed"
        guard case .new(let typed) = scan.discoveredLogin(username: "root") else { Issue.record("not a new login"); return }
        #expect(typed.kind == .password("typed") && typed.label == "root password")
        scan.addJump(server: a.id)
        scan.addJump(server: b.id)
        scan.addJump(server: a.id)
        #expect(scan.addJumps == [.server(a.id), .server(b.id)] && scan.jumpTitles == ["a", "b"])
        scan.moveJumpEarlier(1)
        #expect(scan.jumpTitles == ["b", "a"])
        scan.removeJump(0)
        #expect(scan.addJumps == [.server(a.id)])
    }

    @Test func rdpOfASavedHostJoinsItOnlyWhenAsked() async throws {
        let nas = Server(name: "nas", host: "192.0.2.2", username: "admin")
        let doc = TestDocument(Vault(servers: [nas]))
        let scanner = NetworkScanner(probe: ScriptedProbe(open: ["192.0.2.2": "", "192.0.2.3": "SSH-2.0-x"]))
        let scan = NetworkScanModel(document: doc, scanner: scanner, suggestedRange: "192.0.2.0/29")
        scan.portsText = "22 3389"
        scan.start()
        await scan.waitUntilDone()
        #expect(scan.selectedHosts.map(\.id).sorted() == ["192.0.2.2:3389", "192.0.2.3:22", "192.0.2.3:3389"])
        #expect(scan.savedServersForScreens.map(\.id) == [nas.id])
        let added = await scan.addSelected(username: "admin", screensJoinSavedServers: true, to: .ungrouped)
        #expect(added == 1)
        #expect(doc.vault.service(.rdp, of: nas.id) != nil)
        let new = try #require(doc.vault.servers.first { $0.host == "192.0.2.3" })
        #expect(new.sshEnabled && doc.vault.service(.rdp, of: new.id) != nil)
    }

    @Test func refusedLoginKeepsTheSelection() async throws {
        let doc = TestDocument(Vault())
        let scanner = NetworkScanner(probe: ScriptedProbe(open: ["192.0.2.2": "SSH-2.0-x"]))
        let scan = NetworkScanModel(document: doc, scanner: scanner, suggestedRange: "192.0.2.0/30")
        scan.portsText = "22"  // SSH only here; screens have their own test
        scan.start()
        await scan.waitUntilDone()
        let added = await scan.addSelected(username: "root", login: .saved(UUID()), to: .ungrouped)
        #expect(added == 0 && scan.error != nil && scan.selection == ["192.0.2.2:22"])
        #expect(doc.vault.servers.isEmpty)
    }

    @Test func tcpProbeSeesOpenRefusedAndBanner() async throws {
        // A listener on 127.0.0.1 that greets like sshd.
        let fd = socket(AF_INET, streamSocketType, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let acceptor = Thread {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            let banner = Array("SSH-2.0-Test_1.0\r\n".utf8)
            _ = write(client, banner, banner.count)
            usleep(200_000)
            close(client)
        }
        acceptor.start()
        #expect(await TCPPortProbe().probe(host: "127.0.0.1", port: port, timeout: .seconds(2)) == .open(firstLine: "SSH-2.0-Test_1.0"))
        // Nothing listens on the port the closed listener had: refused.
        let spare = socket(AF_INET, streamSocketType, 0)
        var other = sockaddr_in()
        other.sin_family = sa_family_t(AF_INET)
        #if !canImport(Glibc)
        other.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)  // Darwin's bind refuses a zero sin_len
        #endif
        other.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &other) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(spare, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var otherLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &other) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(spare, $0, &otherLength) } }
        close(spare)
        #expect(await TCPPortProbe().probe(host: "127.0.0.1", port: Int(UInt16(bigEndian: other.sin_port)), timeout: .seconds(1)) == .refused)
        #expect(await TCPPortProbe().probe(host: "not-an-ip", port: 22, timeout: .seconds(1)) == .closed)
        #expect(LocalSubnets.suggestedRange([.init(name: "eth0", address: "192.0.2.10", netmask: "255.255.255.0")]) != nil)
    }
}

@MainActor @Suite struct SSHConfigRefreshTests {
    @Test func savingRegeneratesTheInclude() async throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let writer = SSHConfigWriter(directory: dir.path + "/rssh")
        let key = Credential(label: "k", kind: .privateKey(pem: testKeyPEM, passphrase: nil))
        let server = Server(name: "Web Box", host: "web.example", username: "deploy", credentialID: key.id)
        var saves = 0
        let doc = SavingVaultDocument(vault: Vault(), save: { _ in saves += 1 },
                                      afterSave: [SSHConfigRefresh.hook(agentSocket: "/run/agent.sock", writer: writer)])
        let list = ServerListModel(document: doc)
        try await doc.commit(Vault(credentials: [key]))
        _ = list
        try await doc.commit(try doc.vault.addingServer(server))
        let config = try String(contentsOfFile: writer.configPath, encoding: .utf8)
        #expect(config.contains("Host web-box web.example") && config.contains("IdentitiesOnly yes"))
        #expect(saves == 2 && doc.lastSaveError == nil)
    }
}

/// SOCK_STREAM as `socket(2)` takes it: an enum on Glibc, a plain Int32 on Darwin.
#if canImport(Glibc)
private let streamSocketType = Int32(SOCK_STREAM.rawValue)
#else
private let streamSocketType = SOCK_STREAM
#endif
