// `rsshterm vault import <file>`: makes this device's vault from a plaintext vault document (the JSON of RSSHKit's
// Vault) with a master password. Refuses when a vault exists. For first setup and tests; the file stays plaintext,
// so delete it afterwards.
import Foundation
import RSSHKit
import RSSHTermLinux

enum VaultImport {
    static func run(file: String, environment: [String: String]) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        let status = UncheckedBox(StatusBox())
        Task.detached {
            status.value.code = await importVault(file: file, environment: environment)
            done.signal()
        }
        done.wait()
        return status.value.code
    }

    final class StatusBox { var code: Int32 = 1 }

    private static func importVault(file: String, environment: [String: String]) async -> Int32 {
        do {
            let vault = try VaultSession.decodePlain(try Data(contentsOf: URL(fileURLWithPath: file)))
            let password = environment["RSSH_MASTER_PASSWORD"] ?? String(cString: getpass("Master password: "))
            let choice = await DesktopSecretStore.select(runner: ProcessCommandRunner(), environment: environment)
            if let warning = choice.warning { fputs("rsshterm: \(warning)\n", stderr) }
            let home = environment["HOME"] ?? NSHomeDirectory()
            let session = VaultSession(store: AppController.localStore(environment: environment, home: home),
                                       deviceKeys: SecretStoreDeviceKeyStore(secrets: choice.store),
                                       deviceName: ProcessInfo.processInfo.hostName)
            guard try await session.load() == .noVault else {
                fputs("rsshterm: a vault exists on this device already; nothing imported\n", stderr)
                return 1
            }
            let created = try await session.create(masterPassword: password, vault: vault)
            print("imported \(created.servers.count) servers and \(created.credentials.count) credentials")
            return 0
        } catch {
            fputs("rsshterm: \((error as? LocalizedError)?.errorDescription ?? "\(error)")\n", stderr)
            return 1
        }
    }
}
