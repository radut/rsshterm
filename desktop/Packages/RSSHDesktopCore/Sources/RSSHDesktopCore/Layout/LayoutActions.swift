import Foundation

extension Window {
    /// The window after a layout action: tabs, panes, focus, zoom, broadcast. `newPane` makes the pane for a new tab
    /// or split (a local shell). Nil when the window closes (its last pane closed). Actions that open UI (host
    /// search, command palette, new window, rename tab, jump switcher) leave the window unchanged; the app handles them.
    public func applying(_ action: DesktopAction, newPane: () -> Pane) -> Window? {
        switch action {
        case .newTab: return addingTab(Tab(pane: newPane()))
        case .closePane: return closingFocusedPane()
        case .splitRight: return updatingSelectedTab { $0.splitting(.right, with: newPane()) }
        case .splitDown: return updatingSelectedTab { $0.splitting(.down, with: newPane()) }
        case .focus(let direction): return updatingSelectedTab { $0.movingFocus(direction) }
        case .nextPane: return updatingSelectedTab { $0.focusingNextPane() }
        case .previousPane: return updatingSelectedTab { $0.focusingPreviousPane() }
        case .resizePane(let direction): return updatingSelectedTab { $0.resizingFocused(direction) }
        case .selectTab(let number): return selectingTab(number: number)
        case .nextTab: return selectingNextTab()
        case .previousTab: return selectingPreviousTab()
        case .moveTabLeft: return movingTab(from: selectedIndex, to: selectedIndex - 1)
        case .moveTabRight: return movingTab(from: selectedIndex, to: selectedIndex + 1)
        case .broadcastCurrentTab: return togglingBroadcast()
        case .equalizePanes: return updatingSelectedTab { $0.equalized() }
        case .toggleZoom: return updatingSelectedTab { $0.togglingZoom() }
        case .movePaneToNewTab: return movingFocusedPaneToNewTab()
        case .swapPane(let direction): return updatingSelectedTab { $0.swappingFocused(direction) }
        case .newWindow, .hostSearch, .commandPalette, .renameTab, .jumpSwitcher,
             .broadcastCurrentOnly, .broadcastAllTabs, .broadcastVisible, .toggleBroadcastSession, .broadcastPicker,
             .biggerFont, .smallerFont, .resetFontSize, .showServers, .quickConnect, .showFiles, .openFileManagerHere,
             .lockVault, .showKeys, .movePaneToNewWindow, .moveTabToNewWindow, .mergeAllWindows, .movePaneMode,
             .duplicateTab, .duplicatePane, .duplicateWindow, .editWindowTitle:
            return self
        }
    }
}
