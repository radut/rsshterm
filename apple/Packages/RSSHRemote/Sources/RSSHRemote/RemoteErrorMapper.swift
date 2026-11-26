import Citadel
import Foundation
import NIOCore
import NIOPosix
import RSSHKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// SwiftNIO / Citadel errors as `SSHFailure`, whose messages a user can act on. (The iOS app's `SSHErrorMapper`
/// does the same and also knows its shell errors.)
public enum RemoteErrorMapper {
    public static func failure(for error: any Error, host: String) -> SSHFailure {
        switch error {
        case let failure as SSHFailure:
            return failure
        case let refusal as HostKeyRefusal:
            switch refusal {
            case .changed(let expected, let presented):
                return .hostKeyChanged(expected: expected.fingerprint, presented: presented.fingerprint)
            case .unknown: return .unknown("the host key was not trusted")
            }
        case is AuthenticationFailed:
            return .authenticationFailed
        case let client as SSHClientError:
            return client == .channelCreationFailed ? .shellFailed("it refused to open a session channel") : .authenticationFailed
        case let channel as ChannelError:
            if case .connectTimeout = channel { return .timedOut(host: host) }
            return .hostUnreachable(host: host, detail: "the connection closed")
        case let connection as NIOConnectionError:
            if let first = connection.connectionErrors.first {
                if let io = first.error as? IOError { return .hostUnreachable(host: host, detail: describe(errno: io.errnoCode)) }
                if let channel = first.error as? ChannelError, case .connectTimeout = channel { return .timedOut(host: host) }
                return .hostUnreachable(host: host, detail: String(describing: first.error))
            }
            return .hostUnreachable(host: host, detail: "the name could not be resolved")
        case let io as IOError:
            return .hostUnreachable(host: host, detail: describe(errno: io.errnoCode))
        default:
            return .unknown(String(describing: error))
        }
    }

    public static func describe(errno code: Int32) -> String {
        switch code {
        case ECONNREFUSED: "the connection was refused (is SSH running on that port?)"
        case EHOSTUNREACH: "no route to the host"
        case ENETUNREACH: "the network is unreachable"
        case ETIMEDOUT: "the connection timed out"
        case ECONNRESET: "the connection was reset"
        default: String(cString: strerror(code))
        }
    }
}
