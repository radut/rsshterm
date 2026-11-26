import Crypto
import Foundation
import Testing
@testable import RSSHKit

@Suite struct DeviceKeyWrapperTests {
    let material = DeviceKeyWrapper.newMaterial()

    @Test func wrapsAndUnwraps() async throws {
        let wrapper = try DeviceKeyWrapper(tag: material.tag, secret: material.secret)
        #expect(wrapper.id == "device:\(material.tag)")
        #expect(DeviceKeyWrapper.isDeviceID(wrapper.id))
        let key = Data((0..<32).map { UInt8($0) })
        let wrapped = try await wrapper.wrap(key)
        #expect(wrapped != key)
        #expect(try await wrapper.unwrap(wrapped) == key)
    }

    @Test func anotherDevicesKeyCannotUnwrap() async throws {
        let mine = try DeviceKeyWrapper(tag: material.tag, secret: material.secret)
        let other = try DeviceKeyWrapper(tag: material.tag, secret: DeviceKeyWrapper.newMaterial().secret)
        let wrapped = try await mine.wrap(Data(repeating: 7, count: 32))
        await #expect(throws: (any Error).self) { try await other.unwrap(wrapped) }
    }

    @Test func rejectsBadMaterial() {
        #expect(throws: (any Error).self) { try DeviceKeyWrapper(tag: "t", secret: Data(count: 16)) }
        #expect(throws: (any Error).self) { try DeviceKeyWrapper(tag: "", secret: Data(count: 32)) }
    }

    /// Create -> save to the file -> "relaunch" (new store on the same file, same device key) -> open.
    @Test func vaultSurvivesARelaunchThroughTheLocalFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-\(UUID().uuidString)/vault.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let wrapper = try DeviceKeyWrapper(tag: material.tag, secret: material.secret)
        let key = VaultCipher.newVaultKey()
        let vault = try Vault().addingServer(Server(name: "web", host: "192.0.2.5", username: "root"))
        let envelope = try await VaultCipher.makeEnvelope(vault, key: key, wrappers: [wrapper])
        _ = try await LocalFileVaultStore(fileURL: url).save(try JSONEncoder().encode(envelope), ifMatch: nil)

        let stored = try #require(try await LocalFileVaultStore(fileURL: url).load())
        let reread = try JSONDecoder().decode(VaultEnvelope.self, from: stored.data)
        let relaunched = try DeviceKeyWrapper(tag: material.tag, secret: material.secret)
        let raw = try await relaunched.unwrap(try #require(reread.wrappedKeys[relaunched.id]))
        #expect(try VaultCipher.open(reread, key: SymmetricKey(data: raw)) == vault)
    }
}
