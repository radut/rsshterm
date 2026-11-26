import Foundation
import Testing
@testable import RSSHKit

@Suite struct AgentResponderTests {
    typealias V = OpenSSHKeyVectors

    func key() throws -> AgentKey {
        try AgentKey.load(Credential(label: "phone key", kind: .privateKey(pem: V.ed25519PEM, passphrase: nil)),
                          decrypt: AgentKeyTests.noDecrypt)
    }

    func signPayload(_ blob: Data, data: Data = Data("x".utf8)) -> Data {
        var writer = SSHWireWriter()
        writer.raw(Data([AgentMessage.signRequest]))
        writer.string(blob)
        writer.string(data)
        writer.uint32(0)
        return writer.data
    }

    @Test func listsTheOfferedKeys() async throws {
        let key = try key()
        let responder = AgentResponder(keys: [key]) { _ in true }
        #expect(await responder.response(to: .requestIdentities) == .identities([key.identity]))
        #expect(await AgentResponder(keys: []) { _ in true }.respond(to: Data([11])) == Data([12, 0, 0, 0, 0]))
    }

    @Test func signsWhenApproved() async throws {
        let key = try key()
        let asked = Box<AgentSignRequest?>(nil)
        let responder = AgentResponder(keys: [key]) { request in asked.value = request; return true }
        let reply = await responder.respond(to: signPayload(key.identity.publicBlob))
        #expect(reply.first == AgentMessage.signResponse)
        #expect(asked.value?.keyLabel == "phone key")
        #expect(asked.value?.algorithm == "ssh-ed25519")
    }

    @Test func deniedOrUnknownKeysFail() async throws {
        let key = try key()
        let denying = AgentResponder(keys: [key]) { _ in false }
        #expect(await denying.respond(to: signPayload(key.identity.publicBlob)) == Data([5]))
        let approving = AgentResponder(keys: [key]) { _ in Issue.record("asked for an unknown key"); return true }
        #expect(await approving.respond(to: signPayload(Data([1, 2, 3]))) == Data([5]))
    }

    @Test func refusesAddRemoveAndLock() async throws {
        let responder = AgentResponder(keys: [try key()]) { _ in true }
        for type: UInt8 in [17, 18, 19, 20, 21, 22, 23, 25, 26, 27] {
            #expect(await responder.respond(to: Data([type])) == Data([5]))
        }
    }
}

@Suite struct AgentApprovalGateTests {
    let request = AgentSignRequest(keyID: UUID(), keyLabel: "k", algorithm: "ssh-ed25519", loginUser: "u")

    @Test func noPromptWhenAskingIsOff() async {
        let gate = AgentApprovalGate(askBeforeUse: false) { _ in Issue.record("prompted"); return .deny }
        #expect(await gate.approve(request))
    }

    @Test func allowOnceAsksAgainNextTime() async {
        let count = Box(0)
        let gate = AgentApprovalGate(askBeforeUse: true) { _ in count.value += 1; return .allowOnce }
        #expect(await gate.approve(request))
        #expect(await gate.approve(request))
        #expect(count.value == 2)
    }

    @Test func allowForSessionRemembersThatKeyOnly() async {
        let count = Box(0)
        let gate = AgentApprovalGate(askBeforeUse: true) { _ in count.value += 1; return .allowForSession }
        #expect(await gate.approve(request))
        #expect(await gate.approve(request))
        #expect(count.value == 1)
        let otherKey = AgentSignRequest(keyID: UUID(), keyLabel: "o", algorithm: "ssh-ed25519", loginUser: nil)
        #expect(await gate.approve(otherKey))
        #expect(count.value == 2)
    }

    @Test func denyRefuses() async {
        let gate = AgentApprovalGate(askBeforeUse: true) { _ in .deny }
        #expect(await gate.approve(request) == false)
    }

    @Test func noAnswerDeniesAfterTheTimeoutAndCancelsThePrompt() async {
        let cancelled = Box(false)
        let gate = AgentApprovalGate(askBeforeUse: true, timeout: .milliseconds(50)) { _ in
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelled.value = true
            }
            return .allowOnce
        }
        let start = ContinuousClock.now
        #expect(await gate.approve(request) == false)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(cancelled.value)
    }

    @Test func defaultTimeoutIsThirtySeconds() {
        #expect(AgentApprovalGate.defaultTimeout == .seconds(30))
    }
}

/// A mutable value shared with @Sendable closures in tests.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
