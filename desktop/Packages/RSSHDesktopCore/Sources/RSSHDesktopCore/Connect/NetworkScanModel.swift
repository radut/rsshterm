import Foundation
import Observation
import RSSHKit

/// The network scan window: a range (prefilled from this computer's subnet), ports, the hosts found so far with
/// a checkbox each (new ones checked, saved ones greyed), and "Add (N)" into Servers / a folder / a new folder.
/// Same behaviour as the iOS scan screen; the desktop probes with `TCPPortProbe` (no Bonjour yet).
@MainActor @Observable
public final class NetworkScanModel {
    public var rangeText: String
    /// SSH, RDP and VNC / Screen Sharing unless the user types other ports.
    public var portsText = ScanPorts.defaultText
    /// Hides hosts found only by a non-SSH port.
    public var onlySSH = false
    public private(set) var found: [DiscoveredHost] = []
    public var selection: Set<DiscoveredHost.ID> = []
    public private(set) var progress: ScanProgress?
    public private(set) var isScanning = false
    /// The range of the last scan, as typed: the default name of a new folder.
    public private(set) var scannedRange = ""
    public var error: String?
    /// "Add": how the new servers log in (none, a saved password or key, or a new password typed in `newPassword`).
    public var addLogin: ServerEditorModel.Login = .none
    public var newPassword = ""
    /// "Add": saved servers the new ones jump through, first hop first.
    public private(set) var addJumps: [JumpHost] = []

    @ObservationIgnored public let document: any VaultDocument
    @ObservationIgnored private let scanner: NetworkScanner
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(document: any VaultDocument, scanner: NetworkScanner = NetworkScanner(probe: TCPPortProbe()),
                suggestedRange: String? = LocalSubnets.suggestedRange()) {
        self.document = document
        self.scanner = scanner
        rangeText = suggestedRange ?? ""
    }

    public func isSaved(_ host: DiscoveredHost) -> Bool { document.vault.hasServer(host: host.host, port: host.port) }

    public var visible: [DiscoveredHost] { onlySSH ? found.filter(\.hasSSH) : found }
    public var selectedHosts: [DiscoveredHost] { visible.filter { selection.contains($0.id) && !isSaved($0) } }

    public func selectAll() { selection = Set(visible.filter { !isSaved($0) }.map(\.id)) }
    public func selectNone() { selection = [] }

    public func toggle(_ host: DiscoveredHost) {
        guard !isSaved(host) else { return }
        if selection.contains(host.id) { selection.remove(host.id) } else { selection.insert(host.id) }
    }

    public func start() {
        stop()
        let range: NetworkRange, ports: [Int]
        do {
            range = try NetworkRange(parsing: rangeText)
            ports = try ScanPorts.parse(portsText)
        } catch {
            self.error = error.localizedDescription
            return
        }
        error = nil
        found = []
        selection = []
        scannedRange = rangeText.trimmingCharacters(in: .whitespacesAndNewlines)
        progress = ScanProgress(done: 0, total: range.hosts.count)
        isScanning = true
        let scanner = scanner
        task = Task { [weak self] in
            for await event in scanner.scan(range, ports: ports) {
                guard let self else { break }
                switch event {
                case .found(let host): add(host)
                case .progress(let value): progress = value
                }
            }
            self?.isScanning = false
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    /// Waits for the running scan to end (tests, and "Add" pressed while the last hosts come in).
    public func waitUntilDone() async { await task?.value }

    /// The vault's keys, then its passwords: the saved logins "Add" offers (as Quick Connect lists them).
    public var savedLogins: [Credential] {
        document.vault.credentials(for: .key) + document.vault.credentials(for: .password)
    }

    /// Saved servers that a checked RDP (3389) or VNC (5900) host would join: when not empty, "Add" asks
    /// "Add the screens to <servers>" or "Keep as separate servers" (`addSelected(screensJoinSavedServers:)`).
    public var savedServersForScreens: [Server] { document.vault.serversForDiscoveredScreens(selectedHosts) }

    /// Saved servers a new one can jump through, in vault order.
    public var jumpCandidates: [Server] { document.vault.servers }

    /// `addLogin` for `addSelected`: a new password is saved once, as "user@range".
    public func discoveredLogin(username: String) -> DiscoveredLogin {
        switch addLogin {
        case .none: .none
        case .saved(let id): .saved(id)
        case .newPassword: .newPassword(newPassword, label: newPasswordLabel(username: username))
        }
    }

    /// Each jump as the list shows it (a saved server's name).
    public var jumpTitles: [String] {
        addJumps.map { jump in
            switch jump {
            case .server(let id): document.vault.servers.first { $0.id == id }?.name ?? "(deleted server)"
            case .inline(let hop): hop.displayName
            }
        }
    }

    public func addJump(server id: UUID) {
        guard !addJumps.contains(.server(id)) else { return }
        addJumps.append(.server(id))
    }

    public func removeJump(_ index: Int) {
        guard addJumps.indices.contains(index) else { return }
        addJumps.remove(at: index)
    }

    public func moveJumpEarlier(_ index: Int) {
        guard index > 0, addJumps.indices.contains(index) else { return }
        addJumps.swapAt(index, index - 1)
    }

    /// The label a password typed for this scan is saved under ("user@range").
    public func newPasswordLabel(username: String) -> String {
        DiscoveredLogin.label(username: username, range: scannedRange)
    }

    /// Adds the checked hosts as servers logging in as `username` with `login`, through `jumpHosts`; returns how
    /// many were added (saved and duplicate hosts are skipped). A refused edit keeps the selection and sets `error`.
    @discardableResult
    public func addSelected(username: String, login: DiscoveredLogin = .none, jumpHosts: [JumpHost] = [],
                            screensJoinSavedServers: Bool = false, to destination: ScanDestination) async -> Int {
        let hosts = selectedHosts
        var added = 0
        let result = await commitEdit { vault throws(VaultEditError) in
            let imported = try vault.addingDiscovered(hosts, to: destination, username: username, login: login,
                                                      jumpHosts: jumpHosts,
                                                      screensJoinSavedServers: screensJoinSavedServers)
            added = imported.added.count
            return imported.vault
        }
        guard result != nil else { return 0 }
        selection.subtract(hosts.map(\.id))
        return added
    }

    /// New hosts start checked unless already saved.
    private func add(_ host: DiscoveredHost) {
        let isNew = !found.contains { $0.id == host.id }
        // A host's non-SSH answer gives way to its SSH one, except a screen (RDP, VNC): that is a service of its own.
        found = found.filter { !($0.host == host.host && !$0.hasSSH && host.hasSSH && ScreenService(port: $0.port) == nil) }
            .adding(host)
        if isNew && !isSaved(host) { selection.insert(host.id) }
    }

    /// Runs a vault edit through the document and keeps its error for the UI.
    private func commitEdit(_ change: (Vault) throws(VaultEditError) -> Vault) async -> Vault? {
        let outcome = await VaultEdits.apply(document, change)
        error = outcome.error
        return outcome.vault
    }
}
