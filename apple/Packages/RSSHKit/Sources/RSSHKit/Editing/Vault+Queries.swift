import Foundation

/// How a server logs in, as the editor shows it.
public enum LoginMethod: String, CaseIterable, Hashable, Sendable {
    case none, password, key

    public var title: String {
        switch self {
        case .none: "None"
        case .password: "Password"
        case .key: "Key"
        }
    }
}

extension Vault {
    /// Servers whose name, host, user name, folder name, tags or notes contain `query` (case and accents ignored), in vault order.
    /// A blank query matches every server.
    public func searchingServers(_ query: String) -> [Server] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return servers }
        let folderNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        return servers.filter { server in
            let folder = server.groupID.flatMap { folderNames[$0] } ?? ""
            return ([server.name, server.host, server.username, folder, server.notes ?? ""] + server.tags).contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    public func loginMethod(for credentialID: UUID?) -> LoginMethod {
        guard let credentialID, let credential = credentials.first(where: { $0.id == credentialID }) else { return .none }
        return credential.isPassword ? .password : .key
    }

    public func credentials(for method: LoginMethod) -> [Credential] {
        switch method {
        case .none: []
        case .password: credentials.filter(\.isPassword)
        case .key: credentials.filter(\.isPrivateKey)
        }
    }
}
