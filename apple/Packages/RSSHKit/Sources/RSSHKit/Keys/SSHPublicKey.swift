import Foundation

/// The one-line public key format of `authorized_keys` and `.pub` files: `<type> <base64 blob> [comment]`.
public enum SSHPublicKey {
    public static let ed25519Type = "ssh-ed25519"

    /// The wire blob of an ed25519 public key: string "ssh-ed25519", string <32 bytes>.
    public static func ed25519Blob(_ publicKey: Data) -> Data {
        var writer = SSHWireWriter()
        writer.string(ed25519Type)
        writer.string(publicKey)
        return writer.data
    }

    public static func line(type: String, blob: Data, comment: String?) -> String {
        let base = "\(type) \(blob.base64EncodedString())"
        guard let comment, !comment.isEmpty else { return base }
        return "\(base) \(comment)"
    }

    public static func ed25519Line(publicKey: Data, comment: String?) -> String {
        line(type: ed25519Type, blob: ed25519Blob(publicKey), comment: comment)
    }
}
