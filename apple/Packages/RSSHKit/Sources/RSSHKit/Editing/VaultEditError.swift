import Foundation

/// Why a vault edit was refused. Messages are shown to the user as they are.
public enum VaultEditError: Error, Equatable, Sendable, LocalizedError {
    case unknownServer
    case unknownGroup
    case unknownCredential
    case duplicateID
    case emptyName
    case groupNameTaken
    case emptySecret
    case invalidKey(String)
    /// The credential is still used by these servers (by name).
    case credentialInUse([String])
    case unknownRemoteDesktop
    /// A remote desktop's login must be a password, not an SSH key.
    case needsPassword
    case invalidAddress(ConnectionTarget.ValidationError)
    /// The server still carries the tunnel of these remote desktops (by name).
    case serverInUse([String])
    /// An SSH transport without a server to go through.
    case needsTunnelServer
    /// The server's jump chain cannot be followed (a circle, too long, a deleted jump server).
    case jumpChain(JumpChainError)
    /// The server is a jump host of these servers (by name).
    case usedAsJumpHost([String])
    /// A server opened with nothing: neither SSH nor a screen.
    case noService
    /// The server already has a screen of this kind (its title).
    case serviceExists(String)

    public var errorDescription: String? {
        switch self {
        case .unknownServer: "That server no longer exists."
        case .unknownGroup: "That folder no longer exists."
        case .unknownCredential: "That password or key no longer exists."
        case .duplicateID: "That item is already saved."
        case .emptyName: "Enter a name."
        case .groupNameTaken: "A folder with that name already exists."
        case .emptySecret: "Enter the password."
        case .invalidKey(let reason): reason
        case .credentialInUse(let servers):
            "Still used by \(servers.joined(separator: ", ")). Pick another login for those servers first."
        case .unknownRemoteDesktop: "That remote desktop no longer exists."
        case .needsPassword: "A screen opens with a password, not an SSH key. Pick a password."
        case .invalidAddress(let reason): reason.message
        case .needsTunnelServer: "Pick the SSH server to connect through, or choose a direct connection."
        case .serverInUse(let names):
            "\(names.joined(separator: ", ")) connect through this server. Pick another tunnel for them first."
        case .jumpChain(let error): error.message
        case .usedAsJumpHost(let servers):
            "\(servers.joined(separator: ", ")) connect through this server. Remove it from their Jump Through list first."
        case .noService: "Turn on SSH, RDP or VNC: a server needs a way to open it."
        case .serviceExists(let title): "This server already has \(title). Edit that one instead."
        }
    }
}
