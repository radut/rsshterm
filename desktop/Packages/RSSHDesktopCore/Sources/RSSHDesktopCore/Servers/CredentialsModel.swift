import Foundation
import Observation
import RSSHKit

/// Passwords and keys of the vault (the "Keys" window): list with which servers use each, add a password, import a
/// key (OpenSSH, PEM, PuTTY; converted to OpenSSH), generate an ed25519 key, rename, delete (refused while a server
/// logs in with it), and copy a key's public line. Secrets never leave the vault except the public line.
@MainActor @Observable
public final class CredentialsModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public let credential: Credential
        /// Server names that log in with it.
        public let usedBy: [String]
        /// "ssh-ed25519", "ssh-rsa" ... for keys; nil for passwords.
        public let keyType: String?
        /// The public line to paste into authorized_keys; nil for passwords.
        public let publicLine: String?

        public var id: UUID { credential.id }
    }

    public var error: String?
    @ObservationIgnored public let document: any VaultDocument

    public init(document: any VaultDocument) { self.document = document }

    public var rows: [Row] {
        let vault = document.vault
        return vault.credentials.map { credential in
            let info = credential.keyInfo
            return Row(credential: credential, usedBy: vault.servers(using: credential.id).map(\.name),
                       keyType: info?.keyType, publicLine: info?.publicLine)
        }
    }

    @discardableResult
    public func addPassword(label: String, password: String) async -> Credential? {
        await add(Credential(label: label, kind: .password(password)))
    }

    /// What the import sheet shows before asking for a passphrase.
    public func previewKey(_ text: String) -> Result<KeyImportPreview, KeyImportError> {
        do { return .success(try KeyImport.preview(text)) } catch { return .failure(error) }
    }

    /// Imports a private key (any supported format) as an OpenSSH key credential.
    @discardableResult
    public func importKey(_ text: String, passphrase: String?, label: String) async -> Credential? {
        do {
            let imported = try KeyImport.convert(text, passphrase: passphrase, comment: label)
            return await add(Credential(label: label, kind: .privateKey(pem: imported.pem, passphrase: imported.passphrase)))
        } catch {
            self.error = error.errorDescription
            return nil
        }
    }

    /// A new ed25519 key; its public line is in the returned row (`rows`) to copy to servers.
    @discardableResult
    public func generateKey(label: String) async -> Credential? {
        let pair = Ed25519KeyPair.generate(comment: label)
        return await add(Credential(label: label, kind: .privateKey(pem: OpenSSHPrivateKey.encode(pair), passphrase: nil)))
    }

    @discardableResult
    public func rename(_ id: UUID, to label: String) async -> Bool {
        guard var credential = document.vault.credentials.first(where: { $0.id == id }) else {
            error = VaultEdits.errorMessage(.unknownCredential)
            return false
        }
        credential.label = label
        return await commitEdit { vault throws(VaultEditError) in
            try vault.updatingCredential(credential)
        } != nil
    }

    @discardableResult
    public func delete(_ id: UUID) async -> Bool {
        await commitEdit { vault throws(VaultEditError) in try vault.deletingCredential(id) } != nil
    }

    private func add(_ credential: Credential) async -> Credential? {
        await commitEdit { vault throws(VaultEditError) in
            try vault.addingCredential(credential)
        } == nil ? nil : document.vault.credentials.first { $0.id == credential.id }
    }

    /// Runs a vault edit through the document and keeps its error for the UI.
    private func commitEdit(_ change: (Vault) throws(VaultEditError) -> Vault) async -> Vault? {
        let outcome = await VaultEdits.apply(document, change)
        error = outcome.error
        return outcome.vault
    }
}
