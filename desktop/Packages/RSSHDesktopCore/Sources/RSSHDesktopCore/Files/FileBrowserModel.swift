import Foundation
import Observation
import RSSHKit
import RSSHRemote

/// One file pane: a place, the folder shown, its items (sorted, filtered), the selection and the keyboard cursor,
/// back/forward history, and the operations on one source (new folder, rename, delete). The commander has two.
@MainActor @Observable
public final class FileBrowserModel: Identifiable {
    public enum SortKey: String, CaseIterable, Sendable {
        case name, size, date, kind
    }

    public let id = UUID()
    public private(set) var place: FilePlace
    public private(set) var source: (any FileSource)?
    public private(set) var path: FilePath = .root
    public private(set) var items: [FileItem] = []
    public private(set) var isLoading = false
    public var error: String?
    /// Set when the place needs its host key trusted first; answer with `answerHostKey(trust:)`.
    public private(set) var hostKeyQuestion: KnownHost?
    public var sort: SortKey = .name
    public var ascending = true
    public var showHidden = false
    /// Filter as typed in the pane's search field.
    public var query = ""
    public var selection: Set<FilePath> = []
    /// The row the keyboard is on (arrows move it, Space/Insert toggles its selection, Enter opens it).
    public var cursor: FilePath?
    public private(set) var back: [FilePath] = []
    public private(set) var forward: [FilePath] = []

    @ObservationIgnored public let places: FilePlaces
    /// Where the first load opens (else the source's home).
    @ObservationIgnored public var startPath: FilePath?

    public init(place: FilePlace, places: FilePlaces, startPath: FilePath? = nil) {
        self.place = place
        self.places = places
        self.startPath = startPath
    }

    public var title: String { path.isRoot || source == nil ? places.title(of: place) : path.name }
    public var placeTitle: String { places.title(of: place) }

    /// Hidden files and the search applied, folders first, then the chosen order.
    public var visibleItems: [FileItem] {
        let filtered = items.filter {
            (showHidden || !$0.isHidden) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let ordered: Bool = switch sort {
            case .name: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size: (lhs.size ?? 0, lhs.name) < (rhs.size ?? 0, rhs.name)
            case .date: (lhs.modified ?? .distantPast, lhs.name) < (rhs.modified ?? .distantPast, rhs.name)
            case .kind: (lhs.path.pathExtension.lowercased(), lhs.name) < (rhs.path.pathExtension.lowercased(), rhs.name)
            }
            return ascending ? ordered : !ordered
        }
    }

    /// Click on a column header: that key, or the other direction when it is already the key.
    public func sort(by key: SortKey) {
        if sort == key { ascending.toggle() } else { sort = key; ascending = true }
    }

    /// "7 folders, 1 file" (and "3 selected, 12 MB") under the list.
    public var summary: String {
        let shown = visibleItems
        let folders = shown.filter(\.isDirectory).count
        let files = shown.count - folders
        var text = "\(folders) \(folders == 1 ? "folder" : "folders"), \(files) \(files == 1 ? "file" : "files")"
        if !selection.isEmpty {
            let bytes = selectedItems.compactMap(\.size).reduce(0, +)
            text += ", \(selection.count) selected (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
        }
        return text
    }

    /// The selection, or the cursor's item when nothing is selected (what F5/F6/F8 act on).
    public var targets: [FileItem] {
        let selected = selectedItems
        if !selected.isEmpty { return selected }
        return cursor.flatMap { c in items.first { $0.path == c } }.map { [$0] } ?? []
    }

    public var selectedItems: [FileItem] { visibleItems.filter { selection.contains($0.path) } }
    public var cursorItem: FileItem? { cursor.flatMap { c in items.first { $0.path == c } } }

    // MARK: navigation

    /// Opens the place (first call) and lists the current folder.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if source == nil {
                let opened = try await places.source(for: place)
                source = opened
                path = startPath ?? opened.home
            }
            guard let source else { return }
            items = try await source.list(path)
            selection = selection.filter { selected in items.contains { $0.path == selected } }
            if let cursor, !items.contains(where: { $0.path == cursor }) { self.cursor = visibleItems.first?.path }
            if cursor == nil { cursor = visibleItems.first?.path }
            error = nil
        } catch PlaceOpenError.unknownHostKey(let key) {
            hostKeyQuestion = key
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            // A dropped connection: open the place again next time.
            if source is SFTPFileSource, !(error is FileSourceError) { places.forget(place); source = nil }
        }
    }

    public func open(_ directory: FilePath) async {
        if directory != path { back.append(path); forward = [] }
        await show(directory)
    }

    /// Enter / double click: a folder opens; a file is returned for the caller to view or edit.
    public func activate(_ item: FileItem) async -> FileItem? {
        guard item.isDirectory else { return item }
        await open(item.path)
        return nil
    }

    public func goUp() async {
        guard !path.isRoot else { return }
        let from = path
        await open(path.parent)
        cursor = from
    }

    public func goBack() async {
        guard let previous = back.popLast() else { return }
        forward.append(path)
        await show(previous)
    }

    public func goForward() async {
        guard let next = forward.popLast() else { return }
        back.append(path)
        await show(next)
    }

    /// Points the pane at another place (the place picker).
    public func switchTo(_ newPlace: FilePlace, at start: FilePath? = nil) async {
        place = newPlace
        source = nil
        items = []
        selection = []
        cursor = nil
        back = []
        forward = []
        startPath = start
        await load()
    }

    public func answerHostKey(trust: Bool) async {
        guard let key = hostKeyQuestion else { return }
        hostKeyQuestion = nil
        guard trust else {
            error = SSHFailure.hostKeyRejectedByUser.message
            return
        }
        do { try await places.trust(key) } catch { self.error = error.localizedDescription }
        await load()
    }

    // MARK: keyboard

    /// Arrow keys: moves the cursor `by` rows (negative: up), clamped; with `extend` the rows passed are selected.
    public func moveCursor(by offset: Int, extend: Bool = false) {
        let list = visibleItems
        guard !list.isEmpty else { cursor = nil; return }
        let current = cursor.flatMap { c in list.firstIndex { $0.path == c } } ?? (offset > 0 ? -1 : list.count)
        let next = min(max(current + offset, 0), list.count - 1)
        if extend {
            let range = min(current, next)...max(current, next)
            for index in range where list.indices.contains(index) { selection.insert(list[index].path) }
        }
        cursor = list[next].path
    }

    /// Space / Insert: toggles the cursor's row and moves down (Midnight Commander's Insert).
    public func toggleCursorSelection() {
        guard let cursor else { return }
        if selection.contains(cursor) { selection.remove(cursor) } else { selection.insert(cursor) }
        moveCursor(by: 1)
    }

    public func selectAll() { selection = Set(visibleItems.map(\.path)) }
    public func clearSelection() { selection = [] }

    // MARK: operations

    public func makeFolder(named name: String) async {
        let target = path.appending(Self.cleanName(name))
        await run { try await $0.makeDirectory(target) }
        cursor = target
    }

    public func rename(_ item: FileItem, to name: String) async {
        let target = item.path.parent.appending(Self.cleanName(name))
        await run { try await $0.rename(item.path, to: target) }
        cursor = target
    }

    public func delete(_ targets: [FileItem]) async {
        await run { source in
            for item in targets { try await source.deleteRecursively(item) }
        }
        selection = []
    }

    /// Lists the folder again (after a transfer into it, or Ctrl/Cmd+R).
    public func refresh() async { await load() }

    /// Runs an operation on the source, shows its error, and lists the folder again.
    /// The operation's error outlives the listing that follows it.
    public func run(_ operation: @escaping (any FileSource) async throws -> Void) async {
        guard let source else { return }
        var failure: String?
        do { try await operation(source) } catch { failure = error.localizedDescription }
        await load()
        if let failure { error = failure }
    }

    /// A name for one path segment: no slashes, not empty.
    public static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "untitled" : trimmed
    }

    private func show(_ directory: FilePath) async {
        path = directory
        selection = []
        query = ""
        cursor = nil
        await load()
    }
}
