import Foundation

/// Where to connect: what Quick Connect asks for and what a `Server` provides.
public struct ConnectionTarget: Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyHost, invalidHost, invalidPort, emptyUsername

        public var message: String {
            switch self {
            case .emptyHost: return "Enter a host name or address."
            case .invalidHost: return "The host name cannot contain spaces."
            case .invalidPort: return "The port must be a number from 1 to 65535."
            case .emptyUsername: return "Enter a username."
            }
        }
    }

    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    public init(server: Server) {
        self.init(host: server.host, port: server.port, username: server.username)
    }

    /// "user@host", with ":port" when it is not 22.
    public var displayName: String {
        port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
    }

    /// Validates form input; an empty port means 22.
    public static func validated(host: String, port: String, username: String) throws(ValidationError) -> ConnectionTarget {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { throw .emptyHost }
        guard !h.contains(where: \.isWhitespace) else { throw .invalidHost }
        guard !u.isEmpty else { throw .emptyUsername }
        let number = p.isEmpty ? 22 : Int(p)
        guard let number, (1...65535).contains(number) else { throw .invalidPort }
        return ConnectionTarget(host: h, port: number, username: u)
    }
}
