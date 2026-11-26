import Foundation
import Testing
@testable import RSSHKit

@Suite struct VaultEditsTests {
    let home = ServerGroup(name: "Home")
    let lab = ServerGroup(name: "Lab")
    let password = Credential(label: "root pw", kind: .password("s3cret"))
    let vault: Vault

    init() {
        vault = Vault(groups: [home, lab], servers: [
            Server(name: "b", host: "b", username: "u", groupID: home.id),
            Server(name: "a", host: "a", username: "u", groupID: home.id),
            Server(name: "loose", host: "c", username: "u", credentialID: password.id),
        ], credentials: [password])
    }

    // MARK: servers

    @Test func addingAServerReturnsANewVaultAndLeavesTheOldOne() throws {
        let old = vault
        let server = Server(name: "new", host: "n", username: "u", groupID: lab.id)
        let new = try old.addingServer(server)
        #expect(new.servers.last == server)
        #expect(old.servers.count == 3)
    }

    @Test func addingRejectsUnknownLinksAndDuplicates() {
        #expect(throws: VaultEditError.unknownGroup) {
            try vault.addingServer(Server(name: "x", host: "x", username: "u", groupID: UUID()))
        }
        #expect(throws: VaultEditError.unknownCredential) {
            try vault.addingServer(Server(name: "x", host: "x", username: "u", credentialID: UUID()))
        }
        #expect(throws: VaultEditError.duplicateID) { try vault.addingServer(vault.servers[0]) }
    }

    @Test func updatingReplacesInPlace() throws {
        var changed = vault.servers[1]
        changed.port = 2222
        let new = try vault.updatingServer(changed)
        #expect(new.servers[1].port == 2222)
        #expect(new.servers.map(\.id) == vault.servers.map(\.id))
        #expect(throws: VaultEditError.unknownServer) {
            try vault.updatingServer(Server(name: "x", host: "x", username: "u"))
        }
    }

    @Test func deletingServers() throws {
        let gone = vault.servers[0].id
        let new = try vault.deletingServers([gone])
        #expect(new.servers.count == 2 && !new.servers.contains { $0.id == gone })
        #expect(throws: VaultEditError.unknownServer) { try vault.deletingServers([UUID()]) }
    }

    @Test func serversInAGroupKeepVaultOrder() {
        #expect(vault.servers(inGroup: home.id).map(\.name) == ["b", "a"])
        #expect(vault.servers(inGroup: nil).map(\.name) == ["loose"])
        #expect(vault.servers(inGroup: lab.id).isEmpty)
    }

    @Test func reorderingWithinAGroupLeavesOthersAlone() throws {
        let with = try vault.addingServer(Server(name: "c", host: "c", username: "u", groupID: home.id))
        // home is [b, a, c]; drag "c" (offset 2) to the top.
        let moved = with.movingServers(inGroup: home.id, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(moved.servers(inGroup: home.id).map(\.name) == ["c", "b", "a"])
        #expect(moved.servers(inGroup: nil).map(\.name) == ["loose"])
        // drag "c" (offset 0) to the end, SwiftUI style (toOffset is past the end).
        let back = moved.movingServers(inGroup: home.id, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(back.servers(inGroup: home.id).map(\.name) == ["b", "a", "c"])
        let several = with.movingServers(inGroup: home.id, fromOffsets: IndexSet([0, 2]), toOffset: 2)
        #expect(several.servers(inGroup: home.id).map(\.name) == ["a", "b", "c"])
    }

    @Test func movingAServerToAnotherFolder() throws {
        let id = vault.servers[2].id
        let moved = try vault.movingServer(id, toGroup: lab.id)
        #expect(moved.servers(inGroup: lab.id).map(\.name) == ["loose"])
        #expect(try moved.movingServer(id, toGroup: nil).servers(inGroup: nil).map(\.name) == ["loose"])
        #expect(throws: VaultEditError.unknownGroup) { try vault.movingServer(id, toGroup: UUID()) }
        #expect(throws: VaultEditError.unknownServer) { try vault.movingServer(UUID(), toGroup: nil) }
    }

    // MARK: groups

    @Test func addingAndRenamingGroups() throws {
        let ops = ServerGroup(name: " Ops ")
        let added = try vault.addingGroup(ops)
        #expect(added.groups.last?.name == "Ops")
        #expect(throws: VaultEditError.emptyName) { try vault.addingGroup(ServerGroup(name: "  ")) }
        #expect(throws: VaultEditError.groupNameTaken) { try vault.addingGroup(ServerGroup(name: "home")) }
        let renamed = try vault.renamingGroup(lab.id, to: "Lab 2")
        #expect(renamed.groups[1].name == "Lab 2")
        #expect(try vault.renamingGroup(lab.id, to: "lab").groups[1].name == "lab")
        #expect(throws: VaultEditError.groupNameTaken) { try vault.renamingGroup(lab.id, to: "HOME") }
        #expect(throws: VaultEditError.unknownGroup) { try vault.renamingGroup(UUID(), to: "x") }
    }

    @Test func deletingAGroupUngroupsItsServers() throws {
        let new = try vault.deletingGroup(home.id)
        #expect(new.groups == [lab])
        #expect(new.servers(inGroup: nil).map(\.name) == ["b", "a", "loose"])
        #expect(throws: VaultEditError.unknownGroup) { try vault.deletingGroup(UUID()) }
    }

    @Test func reorderingGroups() {
        #expect(vault.movingGroups(fromOffsets: IndexSet(integer: 1), toOffset: 0).groups == [lab, home])
    }

    // MARK: credentials

    @Test func addingCredentialsValidatesThem() throws {
        let key = Credential(label: "laptop", kind: .privateKey(pem: OpenSSHKeyVectors.ed25519PEM, passphrase: nil))
        #expect(try vault.addingCredential(key).credentials.last == key)
        #expect(throws: VaultEditError.emptyName) {
            try vault.addingCredential(Credential(label: " ", kind: .password("x")))
        }
        #expect(throws: VaultEditError.emptySecret) {
            try vault.addingCredential(Credential(label: "x", kind: .password("")))
        }
        #expect(throws: VaultEditError.invalidKey(OpenSSHKeyError.notOpenSSHKey.errorDescription!)) {
            try vault.addingCredential(Credential(label: "x", kind: .privateKey(pem: "nope", passphrase: nil)))
        }
        #expect(throws: VaultEditError.duplicateID) { try vault.addingCredential(password) }
    }

    @Test func updatingACredential() throws {
        var changed = password
        changed.label = "renamed"
        #expect(try vault.updatingCredential(changed).credentials == [changed])
        #expect(throws: VaultEditError.unknownCredential) {
            try vault.updatingCredential(Credential(label: "x", kind: .password("y")))
        }
    }

    @Test func aCredentialInUseCannotBeDeleted() throws {
        #expect(throws: VaultEditError.credentialInUse(["loose"])) { try vault.deletingCredential(password.id) }
        let freed = try vault.updatingServer({ var s = vault.servers[2]; s.credentialID = nil; return s }())
        #expect(try freed.deletingCredential(password.id).credentials.isEmpty)
        #expect(throws: VaultEditError.unknownCredential) { try vault.deletingCredential(UUID()) }
    }

    @Test func errorsReadWell() {
        #expect(VaultEditError.credentialInUse(["a", "b"]).errorDescription?.contains("a, b") == true)
        #expect(VaultEditError.invalidKey("why").errorDescription?.contains("why") == true)
    }
}
