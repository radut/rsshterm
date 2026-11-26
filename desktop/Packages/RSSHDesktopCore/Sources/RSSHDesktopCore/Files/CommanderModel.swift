import Foundation
import Observation
import RSSHKit

/// What the commander can do; the F-keys of Midnight Commander and Total Commander.
public enum CommanderAction: String, CaseIterable, Hashable, Sendable {
    case view           // F3
    case edit           // F4: open in the local editor, upload on save
    case copy           // F5: to the other pane
    case move           // F6: to the other pane
    case rename         // Shift+F6
    case makeFolder     // F7
    case delete         // F8
    case switchPane     // Tab
    case open           // Enter
    case goUp           // Backspace
    case refresh        // Ctrl/Cmd+R
    case swapPanes      // Ctrl+U
    case sameFolder     // Alt/Option+=: the other pane shows this pane's folder
    case toggleSelection // Space / Insert
    case selectAll      // Ctrl/Cmd+A
    case toggleHidden   // Ctrl/Cmd+H (Cmd+Shift+. on the Mac)
}

/// The questions the commander asks the UI. Each returns nil / false when the user cancels.
@MainActor
public protocol CommanderPrompts: AnyObject {
    /// A name field (new folder, rename) with `initial` prefilled.
    func askName(title: String, initial: String) async -> String?
    /// "Delete 3 items?" with a destructive confirm.
    func confirm(_ message: String, destructive: Bool) async -> Bool
    /// F3: show a file (the UI's viewer, read with `FileSource.readAll`).
    func view(_ item: FileItem, in pane: FileBrowserModel)
    /// F4: a remote file is open in the local editor (`RemoteEditSession`); the UI shows its state.
    func editing(_ session: RemoteEditSession)
}

/// Two file panes (left and right, each on any place), the active one, and the F-key actions between them. Copy and
/// move go through the transfer queue (conflicts asked by `TransferCenter.pendingConflict`); when a transfer
/// ends, both panes list again.
@MainActor @Observable
public final class CommanderModel {
    public enum Side: Sendable { case left, right }

    public let left: FileBrowserModel
    public let right: FileBrowserModel
    public var activeSide: Side = .left
    /// The last action's error, as a sentence.
    public var error: String?
    /// Remote files open in the local editor (F4), newest last.
    public private(set) var editSessions: [RemoteEditSession] = []

    @ObservationIgnored public let places: FilePlaces
    @ObservationIgnored public weak var prompts: (any CommanderPrompts)?
    /// Where F4 downloads remote files (a private temp folder by default).
    @ObservationIgnored public var editDirectory: URL = RemoteEditSession.defaultDirectory()
    /// Opens a local file in the user's editor (F4); the app passes `EditorLauncher.open`.
    @ObservationIgnored public var openInEditor: @MainActor (URL) -> Void = { _ in }

    public init(places: FilePlaces, left: FilePlace = .local, right: FilePlace = .local,
                leftStart: FilePath? = nil, rightStart: FilePath? = nil) {
        self.places = places
        self.left = FileBrowserModel(place: left, places: places, startPath: leftStart)
        self.right = FileBrowserModel(place: right, places: places, startPath: rightStart)
    }

    public var active: FileBrowserModel { activeSide == .left ? left : right }
    public var other: FileBrowserModel { activeSide == .left ? right : left }

    public func pane(_ side: Side) -> FileBrowserModel { side == .left ? left : right }

    public func load() async {
        await left.load()
        await right.load()
    }

    /// Runs an action on the active pane (keys, the bottom button bar, menus).
    public func perform(_ action: CommanderAction) async {
        switch action {
        case .switchPane: activeSide = activeSide == .left ? .right : .left
        case .open:
            if let item = active.cursorItem, let file = await active.activate(item) { prompts?.view(file, in: active) }
        case .goUp: await active.goUp()
        case .refresh: await active.refresh()
        case .toggleSelection: active.toggleCursorSelection()
        case .selectAll: active.selectAll()
        case .toggleHidden: active.showHidden.toggle()
        case .view:
            if let item = active.cursorItem, !item.isDirectory { prompts?.view(item, in: active) }
        case .edit: await edit()
        case .copy: await transfer(.copy)
        case .move: await transfer(.move)
        case .rename: await rename()
        case .makeFolder: await makeFolder()
        case .delete: await delete()
        case .swapPanes: await swapPanes()
        case .sameFolder: await other.switchTo(active.place, at: active.path)
        }
    }

    // MARK: transfers

    /// F5/F6: the active pane's targets into the other pane's folder. Returns the queued transfer.
    @discardableResult
    public func transfer(_ operation: TransferOperation) async -> UUID? {
        let items = active.targets
        guard !items.isEmpty, let from = active.source, let to = other.source else { return nil }
        if from.id == to.id, active.path == other.path {
            error = "Both panes show the same folder."
            return nil
        }
        let request = TransferRequest(source: from, items: items.map(\.path), destination: to,
                                      destinationDirectory: other.path, operation: operation)
        return await enqueue(request, refreshing: [active, other])
    }

    /// Files dropped from Finder / the Linux file manager onto a pane: copied into its folder.
    @discardableResult
    public func dropLocalFiles(_ urls: [URL], onto side: Side) async -> UUID? {
        let pane = pane(side)
        guard let to = pane.source, !urls.isEmpty else { return nil }
        let request = TransferRequest(source: LocalDisk.source(), items: urls.map { FilePath($0.path) }, destination: to,
                                      destinationDirectory: pane.path, operation: .copy)
        return await enqueue(request, refreshing: [pane])
    }

    /// Items dragged from one pane onto the other: copy (move with the platform's move modifier).
    @discardableResult
    public func dropFromPane(_ items: [FileItem], from side: Side, operation: TransferOperation = .copy) async -> UUID? {
        let source = pane(side), target = side == .left ? right : left
        guard let from = source.source, let to = target.source, !items.isEmpty else { return nil }
        let request = TransferRequest(source: from, items: items.map(\.path), destination: to,
                                      destinationDirectory: target.path, operation: operation)
        return await enqueue(request, refreshing: [source, target])
    }

    private func enqueue(_ request: TransferRequest, refreshing panes: [FileBrowserModel]) async -> UUID {
        let id = await places.transfers.start(request)
        Task { [places] in
            _ = await places.transfers.waitUntilFinished(id)
            for pane in panes { await pane.refresh() }
        }
        return id
    }

    // MARK: single-pane operations

    private func makeFolder() async {
        guard let name = await prompts?.askName(title: "New Folder", initial: "") else { return }
        await active.makeFolder(named: name)
    }

    private func rename() async {
        guard let item = active.cursorItem,
              let name = await prompts?.askName(title: "Rename", initial: item.name), name != item.name else { return }
        await active.rename(item, to: name)
    }

    private func delete() async {
        let items = active.targets
        guard !items.isEmpty else { return }
        let what = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
        let folders = items.contains(where: \.isDirectory) ? " Folders are deleted with everything in them." : ""
        guard await prompts?.confirm("Delete \(what)?\(folders)", destructive: true) == true else { return }
        await active.delete(items)
    }

    private func swapPanes() async {
        let (lp, lpath) = (left.place, left.path)
        let (rp, rpath) = (right.place, right.path)
        await left.switchTo(rp, at: rpath)
        await right.switchTo(lp, at: lpath)
    }

    // MARK: F4

    /// Opens the cursor's file in the local editor: a local file in place, a remote one through a
    /// `RemoteEditSession` (downloaded, watched, uploaded on save).
    public func edit() async {
        guard let item = active.cursorItem, !item.isDirectory, let source = active.source else { return }
        if active.place == .local {
            openInEditor(LocalDisk.url(for: item.path))
            return
        }
        if let running = editSessions.first(where: { $0.sourceID == source.id && $0.remotePath == item.path }) {
            openInEditor(running.localURL)
            prompts?.editing(running)
            return
        }
        do {
            let session = try await RemoteEditSession.start(item, on: source, in: editDirectory)
            editSessions.append(session)
            session.startWatching()
            openInEditor(session.localURL)
            prompts?.editing(session)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Stops watching and removes the local copy of a remote edit.
    public func endEditing(_ session: RemoteEditSession) async {
        await session.finish()
        editSessions.removeAll { $0 === session }
    }

    // MARK: terminal integration

    /// "Open File Manager Here" from a terminal pane: the left pane shows the shell's folder on that place (OSC 7 or
    /// rSshD told us the folder); the right pane stays where it is.
    public func show(_ place: FilePlace, at directory: FilePath) async {
        activeSide = .left
        await left.switchTo(place, at: directory)
    }
}
