import Foundation
import Testing
@testable import RSSHKit

@Suite struct AgentForwardingPolicyTests {
    let login = Credential(label: "login", kind: .privateKey(pem: "a", passphrase: nil))
    let other = Credential(label: "other", kind: .privateKey(pem: "b", passphrase: nil))
    let password = Credential(label: "pw", kind: .password("p"))
    var credentials: [Credential] { [login, other, password] }

    func server(_ settings: ServerAgentSettings?) -> Server {
        Server(name: "s", host: "h", username: "u", credentialID: login.id, agentForwarding: settings)
    }

    func plan(_ settings: ServerAgentSettings?, _ defaults: AgentForwardingDefaults = .init()) -> AgentForwardingPlan? {
        AgentForwardingPlan.plan(server: server(settings), loginCredentialID: login.id, defaults: defaults,
                                 credentials: credentials)
    }

    @Test func offByDefault() {
        #expect(plan(nil) == nil)
        #expect(plan(ServerAgentSettings()) == nil)
    }

    @Test func globalOnForwardsTheServerKeyAndAsks() {
        #expect(plan(nil, .init(forwardAgent: true)) == AgentForwardingPlan(keyIDs: [login.id], askBeforeUse: true))
    }

    @Test func serverOverridesGlobal() {
        #expect(plan(.init(forward: .off), .init(forwardAgent: true)) == nil)
        #expect(plan(.init(forward: .on)) == AgentForwardingPlan(keyIDs: [login.id], askBeforeUse: true))
    }

    @Test func askBeforeUseResolvesServerOverGlobal() {
        #expect(plan(.init(forward: .on, askBeforeUse: .off))?.askBeforeUse == false)
        #expect(plan(.init(forward: .on), .init(askBeforeUse: false))?.askBeforeUse == false)
        #expect(plan(.init(forward: .on, askBeforeUse: .on), .init(askBeforeUse: false))?.askBeforeUse == true)
    }

    @Test func keyScopes() {
        #expect(plan(.init(forward: .on, keys: .allKeys))?.keyIDs == [login.id, other.id])
        #expect(plan(.init(forward: .on, keys: .selected([other.id, password.id, UUID()])))?.keyIDs == [other.id])
        #expect(plan(.init(forward: .on, keys: .selected([])))?.keyIDs == [])
    }

    @Test func passwordServerOffersNoKeyOfItsOwn() {
        let p = AgentForwardingPlan.plan(server: server(.init(forward: .on)), loginCredentialID: password.id,
                                         defaults: .init(), credentials: credentials)
        #expect(p?.keyIDs == [])
    }

    @Test func quickConnectFollowsOnlyTheGlobalDefault() {
        #expect(AgentForwardingPlan.plan(server: nil, loginCredentialID: login.id, defaults: .init(),
                                         credentials: credentials) == nil)
        #expect(AgentForwardingPlan.plan(server: nil, loginCredentialID: login.id, defaults: .init(forwardAgent: true),
                                         credentials: credentials)
            == AgentForwardingPlan(keyIDs: [login.id], askBeforeUse: true))
    }
}

@Suite struct AgentSettingsCodingTests {
    @Test func oldVaultsDecodeWithDefaults() throws {
        let json = """
        {"version":1,"groups":[],"credentials":[],
         "servers":[{"id":"\(UUID().uuidString)","name":"a","host":"h","port":22,"username":"u"}]}
        """
        let vault = try JSONDecoder().decode(Vault.self, from: Data(json.utf8))
        #expect(vault.agentDefaults == AgentForwardingDefaults(forwardAgent: false, askBeforeUse: true, confirmWithFaceID: false))
        #expect(vault.servers.first?.agentForwarding == nil)
    }

    @Test func settingsRoundTrip() throws {
        var vault = Vault(servers: [Server(name: "a", host: "h", username: "u",
                                           agentForwarding: .init(forward: .on, keys: .selected([UUID()]), askBeforeUse: .off))])
        vault.agentDefaults = .init(forwardAgent: true, askBeforeUse: false, confirmWithFaceID: true)
        let decoded = try JSONDecoder().decode(Vault.self, from: try JSONEncoder().encode(vault))
        #expect(decoded == vault)
    }

    @Test func unknownValuesFallBackInsteadOfFailingTheVault() throws {
        let json = #"{"forward":"sometimes","keys":{"future":{}},"askBeforeUse":"off"}"#
        let settings = try JSONDecoder().decode(ServerAgentSettings.self, from: Data(json.utf8))
        #expect(settings == ServerAgentSettings(forward: .default, keys: .serverKey, askBeforeUse: .off))
        let defaults = try JSONDecoder().decode(AgentForwardingDefaults.self, from: Data(#"{"forwardAgent":"x"}"#.utf8))
        #expect(defaults == AgentForwardingDefaults())
    }

    @Test func draftCarriesTheSettings() throws {
        let settings = ServerAgentSettings(forward: .on, keys: .allKeys, askBeforeUse: .on)
        let server = Server(name: "a", host: "h", username: "u", agentForwarding: settings)
        #expect(try ServerDraft(server: server).makeServer(id: server.id) == server)
    }
}
