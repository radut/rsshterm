import Foundation

/// Answers one forwarded agent connection: lists the offered keys and signs with them once the gate allows it.
/// Anything else is refused. Stateless apart from the keys, so one responder can serve every channel of a session.
public struct AgentResponder: Sendable {
    public typealias Approve = @Sendable (AgentSignRequest) async -> Bool

    public let keys: [AgentKey]
    private let approve: Approve

    public init(keys: [AgentKey], approve: @escaping Approve) {
        self.keys = keys
        self.approve = approve
    }

    /// The reply payload (unframed) to one request payload.
    public func respond(to payload: Data) async -> Data {
        await response(to: AgentRequest(payload: payload)).payload
    }

    public func response(to request: AgentRequest) async -> AgentResponse {
        switch request {
        case .requestIdentities:
            return .identities(keys.map(\.identity))
        case .sign(let blob, let data, let flags):
            guard let key = keys.first(where: { $0.identity.publicBlob == blob }) else { return .failure }
            let info = AgentSignRequest(keyID: key.id, keyLabel: key.label, algorithm: key.signatureAlgorithm(flags: flags),
                                        loginUser: AgentSignRequest.loginUser(in: data))
            guard await approve(info), let signature = try? key.sign(data, flags: flags) else { return .failure }
            return .signature(signature)
        case .unsupported:
            return .failure
        }
    }
}
