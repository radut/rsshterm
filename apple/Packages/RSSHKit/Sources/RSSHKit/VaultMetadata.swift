import Foundation

/// The envelope fields that are authenticated with the vault: a store that edits any of them breaks the tag.
public struct VaultMetadata: Hashable, Sendable {
    public var revision: UInt64
    /// Kept to whole milliseconds, so it survives JSON and the AAD is the same on every device.
    public var updatedAt: Date
    public var deviceName: String?

    public init(revision: UInt64, updatedAt: Date, deviceName: String? = nil) {
        self.revision = revision
        self.updatedAt = Date(timeIntervalSince1970: (updatedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.deviceName = deviceName
    }

    /// nil for a legacy envelope (no revision). A revision without updatedAt gets a time that can never match.
    init?(_ envelope: VaultEnvelope) {
        guard let revision = envelope.revision else { return nil }
        self.revision = revision
        self.updatedAt = envelope.updatedAt ?? .distantPast
        self.deviceName = envelope.deviceName
    }

    /// format, revision, updatedAt in ms since 1970, base64 device name; one per line.
    var aad: Data {
        let device = deviceName.map { Data($0.utf8).base64EncodedString() } ?? "-"
        return Data("\(VaultEnvelope.format)\nrevision=\(revision)\nupdatedAt=\(Self.milliseconds(updatedAt))\ndevice=\(device)".utf8)
    }

    /// Milliseconds since 1970 as text; a time a store could fake beyond Int64 (or NaN) becomes "invalid", which no
    /// sealing device ever writes, so the tag check fails instead of the conversion trapping.
    static func milliseconds(_ date: Date) -> String {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        guard ms.isFinite, ms >= -9.0e18, ms <= 9.0e18, let exact = Int64(exactly: ms) else { return "invalid" }
        return String(exact)
    }
}
