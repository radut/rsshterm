import Foundation

/// The ssh-agent protocol (draft-miller-ssh-agent) as far as forwarding needs it: list identities and sign. Every
/// other request (add, remove, lock, extensions) is answered with FAILURE, so a server can never change the keys.
public enum AgentMessage {
    public static let failure: UInt8 = 5
    public static let success: UInt8 = 6
    public static let requestIdentities: UInt8 = 11
    public static let identitiesAnswer: UInt8 = 12
    public static let signRequest: UInt8 = 13
    public static let signResponse: UInt8 = 14

    /// SSH_AGENT_RSA_SHA2_256 / SSH_AGENT_RSA_SHA2_512 in a sign request's flags.
    public static let rsaSHA2_256: UInt32 = 0x02
    public static let rsaSHA2_512: UInt32 = 0x04
}

/// One request from the server's side, already unframed.
public enum AgentRequest: Equatable, Sendable {
    case requestIdentities
    case sign(keyBlob: Data, data: Data, flags: UInt32)
    /// Any other message type, or a known one that does not parse: refused.
    case unsupported(UInt8)

    public init(payload: Data) {
        guard let type = payload.first else { self = .unsupported(0); return }
        var reader = SSHWireReader(payload.dropFirst())
        switch type {
        case AgentMessage.requestIdentities where payload.count == 1:
            self = .requestIdentities
        case AgentMessage.signRequest:
            guard let blob = try? reader.string(), let data = try? reader.string(), let flags = try? reader.uint32(),
                  reader.isAtEnd else { self = .unsupported(type); return }
            self = .sign(keyBlob: blob, data: data, flags: flags)
        default:
            self = .unsupported(type)
        }
    }
}

/// One reply, before framing.
public enum AgentResponse: Equatable, Sendable {
    case failure
    case identities([AgentIdentity])
    case signature(Data)

    public var payload: Data {
        var writer = SSHWireWriter()
        switch self {
        case .failure:
            writer.raw(Data([AgentMessage.failure]))
        case .identities(let identities):
            writer.raw(Data([AgentMessage.identitiesAnswer]))
            writer.uint32(UInt32(identities.count))
            for identity in identities {
                writer.string(identity.publicBlob)
                writer.string(identity.comment)
            }
        case .signature(let blob):
            writer.raw(Data([AgentMessage.signResponse]))
            writer.string(blob)
        }
        return writer.data
    }
}

/// A key as the agent lists it.
public struct AgentIdentity: Equatable, Sendable {
    public let publicBlob: Data
    public let comment: String

    public init(publicBlob: Data, comment: String) {
        self.publicBlob = publicBlob
        self.comment = comment
    }
}
