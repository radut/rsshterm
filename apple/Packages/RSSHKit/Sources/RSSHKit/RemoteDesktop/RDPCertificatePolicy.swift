import Foundation

/// Trust on first use for RDP server certificates, like SSH host keys: the first fingerprint is asked about and
/// pinned in the entry, the same one later connects, another one is refused until the user replaces the pin.
/// FreeRDP sees 127.0.0.1 (the tunnel), never the certificate's name, so the pin is what identifies the server.
public enum RDPCertificatePolicy {
    public enum Verdict: Equatable, Sendable {
        case accept
        case askToTrust
        case changed(expected: String)
        case refuse
    }

    public static func normalized(_ fingerprint: String) -> String {
        fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func evaluate(presented: String, pinned: String?) -> Verdict {
        let presented = normalized(presented)
        guard !presented.isEmpty else { return .refuse }
        guard let pinned = pinned.map(normalized), !pinned.isEmpty else { return .askToTrust }
        return pinned == presented ? .accept : .changed(expected: pinned)
    }
}

extension Vault {
    /// Pins (or replaces the pin of) the certificate of an RDP entry.
    public func pinningRDPCertificate(_ fingerprint: String, for desktopID: UUID) throws(VaultEditError) -> Vault {
        guard var desktop = remoteDesktops.first(where: { $0.id == desktopID }) else { throw .unknownRemoteDesktop }
        desktop.pinnedCertificate = RDPCertificatePolicy.normalized(fingerprint)
        var copy = self
        copy.remoteDesktops = remoteDesktops.map { $0.id == desktopID ? desktop : $0 }
        return copy
    }
}
