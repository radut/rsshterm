import Foundation

/// The start of an RFB (RFC 6143) handshake: the server's version and the security types it offers. Enough to
/// tell, before asking for a password, whether this client can open the screen and how.
public struct RFBServerHello: Equatable, Sendable {
    public var major: Int
    public var minor: Int
    /// In the server's order of preference. Empty with `failureReason` when the server refused at once (too many
    /// attempts, or no type it is willing to use).
    public var securityTypes: [RFBSecurityType]
    public var failureReason: String?

    /// macOS Screen Sharing answers "RFB 003.889".
    public var isApple: Bool { major == 3 && minor == 889 }
}

/// RFB security type numbers (IANA "Remote Framebuffer Security Types"; 30-35 are registered to Apple).
public struct RFBSecurityType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let none = Self(rawValue: 1)
    public static let vncPassword = Self(rawValue: 2)
    public static let tight = Self(rawValue: 16)
    public static let veNCrypt = Self(rawValue: 19)
    /// Apple Remote Desktop: Diffie-Hellman + AES-128 over the macOS account (rfbproto "Diffie-Hellman
    /// Authentication"). The one Apple type RoyalVNCKit implements.
    public static let appleDiffieHellman = Self(rawValue: 30)
    /// Apple's later account types, undocumented (RSA/SRP based per public reverse engineering); RoyalVNCKit
    /// does not implement them.
    public static let apple33 = Self(rawValue: 33)
    public static let apple35 = Self(rawValue: 35)
    public static let apple36 = Self(rawValue: 36)
    public static let ultraVNCMSLogonII = Self(rawValue: 113)

    public var description: String {
        switch self {
        case .none: "None (1)"
        case .vncPassword: "VNC password (2)"
        case .tight: "Tight (16)"
        case .veNCrypt: "VeNCrypt (19)"
        case .appleDiffieHellman: "Apple Remote Desktop DH (30)"
        case .apple33, .apple35, .apple36: "Apple (\(rawValue))"
        case .ultraVNCMSLogonII: "UltraVNC MS-Logon II (113)"
        default: "type \(rawValue)"
        }
    }

    /// The types this app's client (RoyalVNCKit) can complete.
    public static let supported: Set<RFBSecurityType> = [.none, .vncPassword, .appleDiffieHellman, .ultraVNCMSLogonII]
}

public enum RFBHandshakeError: Error, Equatable, Sendable, LocalizedError {
    case notRFB(String)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .notRFB(let greeting): "This is not a VNC server (it said \"\(greeting)\")."
        case .truncated: "The VNC server closed the connection during the handshake."
        }
    }
}

/// Byte-level parsing of the first two server messages, kept apart from the socket so it is tested on bytes.
public enum RFBHandshake {
    public static let versionLength = 12

    /// Parses "RFB xxx.yyy\n".
    public static func parseVersion(_ bytes: [UInt8]) throws(RFBHandshakeError) -> (major: Int, minor: Int) {
        guard bytes.count >= versionLength else { throw .truncated }
        let text = String(decoding: bytes.prefix(versionLength), as: UTF8.self)
        let printable = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("RFB "), text.hasSuffix("\n"),
              let major = Int(text.dropFirst(4).prefix(3)), let minor = Int(text.dropFirst(8).prefix(3)),
              text[text.index(text.startIndex, offsetBy: 7)] == "." else {
            throw .notRFB(printable)
        }
        return (major, minor)
    }

    /// What the client answers: 3.8 to any server at or above it (Apple's 3.889 included), 3.7 to 3.7, else 3.3.
    public static func clientVersion(major: Int, minor: Int) -> [UInt8] {
        let minor = major > 3 || minor >= 8 ? 8 : (minor == 7 ? 7 : 3)
        return Array("RFB 003.00\(minor)\n".utf8)
    }

    /// The security message that follows the version. 3.7+: count, types (count 0: u32 length + reason).
    /// 3.3: one u32 type chosen by the server (0: u32 length + reason). Returns nil while more bytes are needed.
    public static func parseSecurity(_ bytes: [UInt8], major: Int, minor: Int)
        -> (types: [RFBSecurityType], reason: String?)? {
        if major == 3, minor < 7 {
            guard bytes.count >= 4 else { return nil }
            let type = u32(bytes, 0)
            if type == 0 { return reason(bytes, at: 4).map { ([], $0) } }
            return ([RFBSecurityType(rawValue: UInt8(truncatingIfNeeded: type))], nil)
        }
        guard let count = bytes.first else { return nil }
        if count == 0 { return reason(bytes, at: 1).map { ([], $0) } }
        guard bytes.count >= 1 + Int(count) else { return nil }
        return (bytes[1...Int(count)].map(RFBSecurityType.init(rawValue:)), nil)
    }

    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    /// Reason strings are capped at 4 KiB: a server cannot make the probe wait for gigabytes.
    private static func reason(_ b: [UInt8], at: Int) -> String?? {
        guard b.count >= at + 4 else { return nil }
        let length = min(Int(u32(b, at)), 4096)
        guard b.count >= at + 4 + length else { return nil }
        return .some(String(decoding: b[(at + 4)..<(at + 4 + length)], as: UTF8.self))
    }
}

// MARK: advice

/// What the app should do with a screen, from what its server offers and what the entry says.
public enum VNCAuthPlan: Equatable, Sendable {
    /// Open it here with RoyalVNCKit using this security type.
    case inApp(RFBSecurityType)
    /// Only Apple's newer account types (33/35/36) are offered: this client cannot log in. On a Mac open it in
    /// Screen Sharing.app; elsewhere set a VNC password on the Mac (System Settings › General › Sharing ›
    /// Screen Sharing › (i) › "VNC viewers may control screen with password").
    case screenSharingAppOnly
    /// Nothing offered that this client implements.
    case unsupported([RFBSecurityType])
    /// The server refused before authentication, with its reason.
    case refused(String)

    public static func plan(for hello: RFBServerHello, preferAccount: Bool) -> VNCAuthPlan {
        if let reason = hello.failureReason, hello.securityTypes.isEmpty { return .refused(reason) }
        let offered = hello.securityTypes
        // An entry for a Mac account wants ARD; a VNC entry wants the password. Either falls back to the other.
        let order: [RFBSecurityType] = preferAccount
            ? [.appleDiffieHellman, .vncPassword, .ultraVNCMSLogonII, .none]
            : [.vncPassword, .none, .appleDiffieHellman, .ultraVNCMSLogonII]
        if let pick = order.first(where: offered.contains) { return .inApp(pick) }
        if offered.contains(where: { [.apple33, .apple35, .apple36].contains($0) }) { return .screenSharingAppOnly }
        return .unsupported(offered)
    }
}
