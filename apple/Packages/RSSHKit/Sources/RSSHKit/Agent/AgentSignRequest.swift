import Foundation

/// What the confirm prompt shows about one sign request.
public struct AgentSignRequest: Equatable, Sendable {
    public let keyID: UUID
    public let keyLabel: String
    /// The algorithm of the signature that would be made (e.g. rsa-sha2-512).
    public let algorithm: String
    /// The user the server's side logs in as, when the data is an SSH public-key login (RFC 4252 §7).
    public let loginUser: String?

    public init(keyID: UUID, keyLabel: String, algorithm: String, loginUser: String?) {
        self.keyID = keyID
        self.keyLabel = keyLabel
        self.algorithm = algorithm
        self.loginUser = loginUser
    }

    /// The public-key methods a login signature names: RFC 4252's, and the host-bound one OpenSSH 8.9+ uses when
    /// the server offers it (PROTOCOL §2.5).
    static let publicKeyMethods: Set<String> = ["publickey", "publickey-hostbound-v00@openssh.com"]

    /// The user name in a userauth signature payload: string session id, byte 50, string user, string service,
    /// string method, ...; nil for anything else (the agent still signs it, the prompt just says less).
    public static func loginUser(in data: Data) -> String? {
        var reader = SSHWireReader(data)
        guard (try? reader.string()) != nil, let marker = try? reader.take(1), marker.first == 50,
              let user = try? reader.text(), let service = try? reader.text(), service == "ssh-connection",
              let method = try? reader.text(), publicKeyMethods.contains(method) else { return nil }
        return user
    }
}
