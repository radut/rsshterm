import Foundation
import RSSHKit
import Testing
@testable import RSSHDesktopCore

@MainActor @Suite struct ServerListModelTests {
    func sample() -> (TestDocument, ServerGroup, Server, Server, Server) {
        let home = ServerGroup(name: "Home")
        var nas = Server(name: "nas", host: "nas.example.org", username: "admin", groupID: home.id)
        nas.tags = ["storage"]
        let ci = Server(name: "ci", host: "ci.example.org", username: "ci", groupID: home.id)
        var web = Server(name: "web", host: "web.example", username: "deploy")
        web.notes = "behind the load balancer"
        return (TestDocument(Vault(groups: [home], servers: [nas, ci, web])), home, nas, ci, web)
    }

    @Test func sectionsSearchAndTags() async {
        let (doc, home, nas, _, web) = sample()
        let list = ServerListModel(document: doc)
        #expect(list.sections.map(\.title) == ["Servers", "Home"])
        #expect(list.sections[1].servers.map(\.name) == ["nas", "ci"])
        list.toggleCollapsed(home.id)
        #expect(list.visibleServers.map(\.name) == ["web"])
        list.query = "balancer"
        #expect(list.sections.map(\.title) == ["Servers"])
        #expect(list.visibleServers == [web])
        list.query = ""
        list.tagFilter = "STORAGE"
        #expect(list.sections.map(\.title) == ["Home"] && list.sections[0].servers == [nas])
        #expect(list.sections[0].isCollapsed == false)
        #expect(list.allTags == ["storage"])
    }

    @Test func foldersAndErrors() async {
        let (doc, home, nas, _, _) = sample()
        let list = ServerListModel(document: doc)
        let work = await list.addGroup(named: " Work ")
        #expect(work != nil && doc.vault.groups.last?.name == "Work")
        #expect(await list.addGroup(named: "home") == nil)
        #expect(list.error == VaultEditError.groupNameTaken.errorDescription)
        #expect(await list.renameGroup(work!, to: "Office"))
        #expect(list.error == nil)
        #expect(await list.deleteGroup(home.id))
        #expect(doc.vault.servers.first { $0.id == nas.id }?.groupID == nil)
    }

    @Test func duplicateMoveDeleteAndKeyboard() async throws {
        let (doc, home, nas, ci, web) = sample()
        let list = ServerListModel(document: doc)
        let copy = try #require(await list.duplicate(nas.id))
        #expect(copy.name == "nas copy" && copy.tags == ["storage"] && copy.groupID == home.id)
        #expect(doc.vault.servers(inGroup: home.id).map(\.name) == ["nas", "nas copy", "ci"])
        #expect(try #require(await list.duplicate(nas.id)).name == "nas copy 2")
        #expect(list.selection.count == 1)

        #expect(await list.move([web.id], toGroup: home.id))
        #expect(doc.vault.servers(inGroup: home.id).last?.id == web.id)
        await list.reorder(inGroup: home.id, fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(doc.vault.servers(inGroup: home.id)[1].id == nas.id)

        list.selection = []
        list.selectNext()
        #expect(list.selectedServers.first?.id == list.visibleServers.first?.id)
        list.selectNext(false)
        #expect(list.selection == [list.visibleServers.last!.id])

        #expect(await list.delete([ci.id]))
        #expect(!doc.vault.servers.contains { $0.id == ci.id })
        #expect(await list.delete([UUID()]) == false)
        #expect(list.error == VaultEditError.unknownServer.errorDescription)
    }

    @Test func aFailedSaveKeepsTheChangeAndSaysSo() async {
        let (doc, _, _, _, _) = sample()
        let list = ServerListModel(document: doc)
        doc.failNextSave = true
        #expect(await list.addGroup(named: "Lab") != nil)
        #expect(list.error?.hasPrefix("Changed here, but not stored") == true)
        #expect(doc.vault.groups.contains { $0.name == "Lab" })
    }

    @Test func importFromSSHConfig() async {
        let (doc, _, _, _, _) = sample()
        let list = ServerListModel(document: doc)
        let key = Credential(label: "id_web", kind: .privateKey(pem: testKeyPEM, passphrase: nil))
        doc.failNextSave = false
        _ = try? await doc.commit(try! doc.vault.addingCredential(key))
        let (candidates, result) = list.importCandidates(sshConfig: """
            Host nas
              HostName nas.example.org
              User admin
            Host build
              HostName build.example
              IdentityFile ~/.ssh/id_web
              ForwardAgent yes
            Host broken
              HostName "a b"
            """, defaultUser: "me")
        #expect(result.entries.count == 3)
        let added = await list.importServers(candidates, to: .newFolder("Imported")) { entry in
            entry.identityFiles.first == "~/.ssh/id_web" ? key.id : nil
        }
        #expect(added == 1)
        let build = doc.vault.servers.first { $0.name == "build" }
        #expect(build?.username == "me" && build?.credentialID == key.id && build?.agentForwarding?.forward == .on)
        #expect(doc.vault.groups.contains { $0.id == build?.groupID && $0.name == "Imported" })

        let (more, _) = list.importCandidates(sshConfig: """
            Host gw
              HostName gw.example.com
              User you
            Host app
              HostName app.example.com
              User deploy
              ProxyJump gw,ops@edge.example.com:2200,nas
            """, defaultUser: nil)
        #expect(await list.importServers(more, to: .ungrouped) == 2)
        let gw = doc.vault.servers.first { $0.name == "gw" }!
        let nas = doc.vault.servers.first { $0.name == "nas" }!
        let app = doc.vault.servers.first { $0.name == "app" }!
        #expect(app.jumpHosts == [.server(gw.id), .inline(InlineJumpHost(host: "edge.example.com", port: 2200, username: "ops")),
                                  .server(nas.id)])
    }
}

@MainActor @Suite struct ServerEditorModelTests {
    @Test func newServerValidatesThenSavesWithANewPassword() async throws {
        let group = ServerGroup(name: "Lab")
        let doc = TestDocument(Vault(groups: [group]))
        let editor = ServerEditorModel(document: doc, groupID: group.id)
        #expect(editor.isNew && editor.title == "New Server")
        #expect(editor.message(for: .host) == nil)
        #expect(await editor.save() == nil)
        #expect(editor.message(for: .host) == ServerDraft.Field.host.message)

        editor.draft.host = "lab.example"
        editor.draft.username = "root"
        editor.draft.port = "2200"
        editor.tagsText = "lab, test ,LAB"
        editor.forwardAgent = .on
        editor.login = .newPassword
        #expect(editor.passwordMessage != nil)
        #expect(!editor.canSave)
        editor.newPassword = "s3cret"
        #expect(editor.canSave && editor.hasChanges)
        let saved = try #require(await editor.save())
        #expect(saved.port == 2200 && saved.tags == ["lab", "test"] && saved.groupID == group.id)
        #expect(saved.agentForwarding?.forward == .on)
        let credential = try #require(doc.vault.credentials.first { $0.id == saved.credentialID })
        #expect(credential.label == "lab.example password" && credential.kind == .password("s3cret"))
        #expect(editor.newPassword.isEmpty && editor.login == .saved(credential.id))
    }

    @Test func editKeepsFieldsAndRefusesUnknownCredential() async throws {
        let key = Credential(label: "k", kind: .privateKey(pem: testKeyPEM, passphrase: nil))
        var server = Server(name: "a", host: "a.example", username: "u", credentialID: key.id)
        server.notes = "n"
        let doc = TestDocument(Vault(servers: [server], credentials: [key]))
        let editor = ServerEditorModel(document: doc, server: server)
        #expect(!editor.isNew && editor.login == .saved(key.id) && editor.keys == [key] && editor.passwords.isEmpty)
        #expect(!editor.hasChanges)
        editor.draft.fontFamily = "Menlo"
        editor.draft.fontSize = 3
        let saved = try #require(await editor.save())
        #expect(saved.notes == "n" && saved.fontSize == TerminalPreferences.fontSizeRange.lowerBound)
        #expect(doc.vault.servers == [saved])

        editor.login = .saved(UUID())
        #expect(await editor.save() == nil)
        #expect(editor.error == VaultEditError.unknownCredential.errorDescription)
    }
}

@MainActor @Suite struct ServerEditorJumpTests {
    @Test func editsTheJumpChainAndRefusesLoops() async throws {
        let bastion = Server(name: "bastion", host: "bastion.example.com", username: "ops")
        let app = Server(name: "app", host: "app.example.com", username: "deploy")
        let doc = TestDocument(Vault(servers: [bastion, app]))
        let editor = ServerEditorModel(document: doc, server: app)
        #expect(editor.jumpCandidates.map(\.name) == ["bastion"])
        editor.addJump(server: bastion.id)
        editor.addJump(server: bastion.id)
        editor.addJump(server: app.id)
        #expect(editor.addJump(address: "you@gw.example.com:2200"))
        #expect(!editor.addJump(address: "not an address"))
        #expect(editor.jumpTitles == ["bastion", "you@gw.example.com:2200"])
        editor.moveJumps(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(editor.jumpTitles.first == "you@gw.example.com:2200")
        editor.removeJumps(atOffsets: IndexSet(integer: 0))
        let saved = try #require(await editor.save())
        #expect(saved.jumpHosts == [.server(bastion.id)])

        // bastion jumping through app would loop.
        let back = ServerEditorModel(document: doc, server: bastion)
        back.addJump(server: app.id)
        #expect(!back.canSave)
        #expect(await back.save() == nil)
        #expect(back.jumpMessage?.contains("circle") == true)
    }
}

@MainActor @Suite struct CredentialsModelTests {
    @Test func addImportGenerateRenameDelete() async throws {
        let doc = TestDocument()
        let model = CredentialsModel(document: doc)
        let password = try #require(await model.addPassword(label: "db", password: "x"))
        #expect(await model.addPassword(label: " ", password: "x") == nil)
        let imported = try #require(await model.importKey(testKeyPEM, passphrase: nil, label: "laptop"))
        let generated = try #require(await model.generateKey(label: "new"))
        #expect(model.rows.count == 3)
        let row = try #require(model.rows.first { $0.id == generated.id })
        #expect(row.keyType == "ssh-ed25519" && row.publicLine?.hasPrefix("ssh-ed25519 ") == true)
        #expect(model.rows.first { $0.id == password.id }?.publicLine == nil)
        if case .failure = model.previewKey(testKeyPEM) { Issue.record("preview failed") }
        #expect(await model.importKey("nonsense", passphrase: nil, label: "x") == nil && model.error != nil)

        let server = Server(name: "s", host: "h", username: "u", credentialID: imported.id)
        try await doc.commit(try doc.vault.addingServer(server))
        #expect(model.rows.first { $0.id == imported.id }?.usedBy == ["s"])
        #expect(await model.delete(imported.id) == false)
        #expect(model.error?.contains("s") == true)
        #expect(await model.rename(generated.id, to: "renamed"))
        #expect(await model.delete(generated.id))
        #expect(doc.vault.credentials.map(\.label).sorted() == ["db", "laptop"])
    }
}

@MainActor @Suite struct ServerEditorServicesTests {
    @Test func newServerIsSSHOnlyAndRDPIsATick() async throws {
        let pw = Credential(label: "pw", kind: .password("x"))
        let doc = TestDocument(Vault(credentials: [pw]))
        let editor = ServerEditorModel(document: doc)
        #expect(editor.draft.sshEnabled && editor.screens.isEmpty)
        editor.draft.host = "win.example.com"
        editor.draft.username = "admin"
        editor.login = .saved(pw.id)
        editor.screens = [.rdp]
        let saved = try #require(await editor.save())
        let rdp = try #require(doc.vault.service(.rdp, of: saved.id))
        #expect(rdp.credentialID == pw.id && rdp.transport == .sshShared)

        let again = ServerEditorModel(document: doc, server: doc.vault.servers[0])
        #expect(again.screens == [.rdp])
        again.draft.sshEnabled = false
        again.screens = []
        #expect(!again.canSave && again.servicesMessage != nil)
        again.screens = [.vnc]
        #expect(again.canSave)
        _ = await again.save()
        #expect(doc.vault.services(of: saved.id).map(\.kind) == [.vnc] && !doc.vault.servers[0].sshEnabled)
    }

    @Test func aNewScreenForASavedHostAsksFirst() async throws {
        let nas = Server(name: "nas", host: "nas.example.com", username: "admin")
        let doc = TestDocument(Vault(servers: [nas]))
        let editor = ServerEditorModel(document: doc)
        editor.draft.host = "NAS.example.com"
        editor.draft.username = "admin"
        #expect(editor.sameHostServers.isEmpty)  // SSH only: nothing to merge
        editor.screens = [.rdp]
        #expect(editor.sameHostServers.map(\.id) == [nas.id])

        // "Keep as a separate server": an ordinary save.
        let separate = ServerEditorModel(document: doc)
        separate.draft.host = "nas.example.com"
        separate.draft.username = "admin"
        separate.draft.sshEnabled = false
        separate.screens = [.rdp]
        #expect(await separate.save() != nil && doc.vault.servers.count == 2)

        // "Add RDP to nas": no new server, the screen joins nas.
        #expect(await editor.addScreens(to: nas.id))
        #expect(doc.vault.servers.count == 2 && doc.vault.service(.rdp, of: nas.id) != nil)
        #expect(doc.vault.servers.first { $0.id == nas.id }?.sshEnabled == true)
    }
}

@MainActor @Suite struct ServerEditorSSHOffTests {
    @Test func turningSSHOffAsksAboutScreensThatTunnelThroughIt() async throws {
        let box = Server(name: "box", host: "192.0.2.5", username: "pi")
        let doc = TestDocument(try Vault(servers: [box]).settingServices(of: box.id, ssh: true, screens: [.vnc]))
        let editor = ServerEditorModel(document: doc, server: doc.vault.servers[0])
        #expect(editor.screensLosingSSH.isEmpty)
        editor.draft.sshEnabled = false
        #expect(editor.screensLosingSSH.count == 1)

        let kept = ServerEditorModel(document: doc, server: doc.vault.servers[0])
        kept.draft.sshEnabled = false
        _ = await kept.save()
        #expect(doc.vault.service(.vnc, of: box.id)?.transport == .sshShared)

        let again = ServerEditorModel(document: doc, server: doc.vault.servers[0])
        again.draft.sshEnabled = false
        _ = await again.save(screensGoDirect: true)
        let vnc = try #require(doc.vault.service(.vnc, of: box.id))
        #expect(vnc.transport == .direct && vnc.host == "192.0.2.5")
    }
}
