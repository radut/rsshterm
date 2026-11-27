// Moves over all windows: the core computes the new windows (LayoutMoves); this applies them, handing live panes
// from window to window, opening and closing windows.
import CGtk
import Foundation
import RSSHDesktopCore
import RSSHTermLinux

extension AppController {
    func mainWindow(id: UUID) -> MainWindow? { windows.first { $0.model?.id == id } }

    func move(pane id: PaneID, to destination: PaneDestination) {
        apply(LayoutMoves.moving(pane: id, to: destination, in: windows.compactMap(\.model)))
    }

    func move(tab id: UUID, to destination: TabDestination) {
        apply(LayoutMoves.moving(tab: id, to: destination, in: windows.compactMap(\.model)))
    }

    func swap(_ a: PaneID, _ b: PaneID) {
        apply(LayoutMoves.swapping(a, b, in: windows.compactMap(\.model)))
    }

    /// Applies a move: panes leaving a window are handed over running; emptied windows close; new ones open.
    func apply(_ move: LayoutMove?) {
        guard let move else { return }
        let before = windows.compactMap(\.model)
        let after = Dictionary(move.windows.map { ($0.id, $0) }) { a, _ in a }
        let pool = PanePool()
        for w in windows {
            guard let old = w.model else { continue }
            let kept = Set(after[old.id]?.tabs.flatMap(\.paneIDs) ?? [])
            w.handOver(Set(old.tabs.flatMap(\.paneIDs)).subtracting(kept), to: pool)
        }
        for w in windows {
            guard let old = w.model else { continue }
            guard let new = after[old.id] else {
                w.setModel(nil) // its last tab moved away
                continue
            }
            guard new != old else { continue }
            w.adopt(pool, for: new)
            w.setModel(new)
        }
        for id in move.openedWindows(from: before) {
            let w = MainWindow(app: self, gtkApp: gtkApp, restoring: after[id], adopting: pool)
            windows.append(w)
            w.present()
        }
        // Nothing should be left; a pane no window took would end here (its deinit hangs up its process).
        mainWindow(id: move.focusedWindow)?.present()
        saveSession()
        stateChanged()
    }

    /// Window and tab names for the Move menus.
    func windowTargets() -> [(UUID, String)] {
        windows.enumerated().compactMap { i, w in
            guard let m = w.model else { return nil }
            let label = w.tabLabels.indices.contains(m.selectedIndex) ? w.tabLabels[m.selectedIndex].title : "Terminal"
            return (m.id, "Window \(i + 1): " + (m.title ?? label))
        }
    }

    func tabTargets() -> [(UUID, Tab, String)] {
        windows.enumerated().flatMap { wi, w -> [(UUID, Tab, String)] in
            guard let m = w.model else { return [] }
            return m.tabs.enumerated().map { ti, tab in
                let label = w.tabLabels.indices.contains(ti) ? w.tabLabels[ti].title : "Tab \(ti + 1)"
                return (m.id, tab, (windows.count > 1 ? "Window \(wi + 1) · " : "") + "\(ti + 1) \(label)")
            }
        }
    }

    // MARK: Drags

    func dragStarted(pane: PaneID) {
        draggedPane = pane
        windows.forEach { $0.setCatching(true) }
    }

    func dragStarted(tab: UUID) {
        draggedPane = nil
        windows.forEach { $0.setCatching(true) }
    }

    func dragEnded() {
        draggedPane = nil
        guard pickingPane == nil else { return }
        // After the drop handlers ran.
        onMain { [weak self] in self?.windows.forEach { $0.setCatching(false) } }
    }

    // MARK: Pick a target

    func startPicking(_ pane: PaneID, in window: MainWindow?) {
        pickingPane = pane
        draggedPane = pane
        for w in windows { w.setCatching(true) }
        window?.showPicking(pane)
        window?.toast("Move pane: click a pane edge, or arrows + Enter (Shift+Enter below), T new tab, N new window, Esc cancels")
    }

    func endPicking() {
        pickingPane = nil
        draggedPane = nil
        for w in windows {
            w.showPicking(nil)
            w.setCatching(false)
        }
    }

    // MARK: Actions

    func perform(_ action: DesktopAction, from w: MainWindow) {
        guard let model = w.model else { return }
        let models = windows.compactMap(\.model)
        let tab = model.selectedTab
        switch action {
        case .movePaneToNewWindow: apply(LayoutMoves.moving(pane: tab.focused, to: .newWindow(), in: models))
        case .moveTabToNewWindow: apply(LayoutMoves.moving(tab: tab.id, to: .newWindow(), in: models))
        case .mergeAllWindows: apply(LayoutMoves.mergingAll(into: model.id, in: models))
        case .movePaneMode: startPicking(tab.focused, in: w)
        case .duplicateTab: w.setModel(model.insertingTab(tab.duplicated { duplicateContent($0, in: w) }, at: nil))
        case .duplicatePane:
            let copy = Pane(content: duplicateContent(tab.focusedPane, in: w))
            w.setModel(model.updatingSelectedTab { $0.splitting(.right, with: copy) })
        case .duplicateWindow:
            openWindow(restoring: Window(tabs: model.tabs.map { $0.duplicated { duplicateContent($0, in: w) } },
                                         selectedIndex: model.selectedIndex, title: model.title))
        case .editWindowTitle: w.editWindowTitle()
        default: break
        }
    }

    /// What a duplicate runs: the same server or screen; a local shell in the folder its shell reported.
    private func duplicateContent(_ pane: Pane, in w: MainWindow) -> PaneContent {
        guard case .localShell(let command, let directory) = pane.content else { return pane.content }
        return .localShell(command: command, directory: w.directories[pane.id] ?? directory)
    }
}
