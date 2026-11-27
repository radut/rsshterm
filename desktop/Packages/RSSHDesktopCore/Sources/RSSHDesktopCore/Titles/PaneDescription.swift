import Foundation
import RSSHKit

/// What a pane is, for lists of panes (the broadcast picker): both apps build their rows from this, so they agree.
public struct PaneDescription: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case localShell, ssh, remoteDesktop

        /// The word for a pane of this kind when nothing else is known yet.
        public var noun: String {
            switch self {
            case .localShell: "Shell"
            case .ssh: "SSH"
            case .remoteDesktop: "Remote desktop"
            }
        }
    }

    public let id: PaneID
    /// Line 1: the pane's tab title as the tab bar shows it (Tab Titles settings), else "Shell — pane 2 in Tab 3".
    public let title: String
    /// Line 2: user@host · folder · foreground program, whatever is known (may be empty).
    public let subtitle: String
    public let kind: Kind
    /// 1-based window, tab and pane (split order) numbers.
    public let window: Int, tab: Int, pane: Int
    /// "Window 2 › Tab 3 › pane 1"; with one window "Tab 3 › pane 1".
    public let location: String
    /// The focused pane ("this pane").
    public let isCurrent: Bool

    /// Every word matches one of the fields (the picker's filter).
    public func matches(_ words: [String]) -> Bool {
        let fields = [title, subtitle, location, kind.noun] + (isCurrent ? ["this pane"] : [])
        return words.allSatisfy { w in fields.contains { FuzzyMatcher.score(w, in: $0) != nil } }
    }
}

extension TabTitleContext {
    /// Line 2 of a picker row: "me@box · ~/git · vim".
    static let paneSubtitle = "{user@host|host}{cwdShort? · {cwdShort}}{process? · {process}}"

    /// Every pane of `windows`, in layout order (windows, tabs, split order), described from the title settings and
    /// the panes' live title facts. `current`: the focused pane.
    public func describePanes(windows: [Window], states: [PaneID: PaneTitleState], current: PaneID?) -> [PaneDescription] {
        windows.enumerated().flatMap { w, window in
            window.tabs.enumerated().flatMap { t, tab in
                tab.panes.enumerated().map { p, pane in
                    describe(pane, in: tab, window: w + 1, tab: t + 1, pane: p + 1, windows: windows.count,
                             state: states[pane.id] ?? PaneTitleState(), current: current)
                }
            }
        }
    }

    private func describe(_ pane: Pane, in tab: Tab, window: Int, tab tabIndex: Int, pane paneIndex: Int, windows: Int,
                          state: PaneTitleState, current: PaneID?) -> PaneDescription {
        let kind: PaneDescription.Kind = switch pane.content {
        case .localShell: .localShell
        case .ssh: .ssh
        case .remoteDesktop: .remoteDesktop
        }
        let facts = sources(for: pane, custom: tab.title, index: tabIndex, state: state).facts()
        var title = settings.label(for: facts).title
        if title == TabTitleSettings.fallbackTitle || title.isEmpty {
            title = "\(kind.noun) — pane \(paneIndex) in Tab \(tabIndex)"
        }
        let subtitle = TabTitleTemplate.render(Self.paneSubtitle, facts, fallback: "")
        let place = "Tab \(tabIndex) › pane \(paneIndex)"
        return PaneDescription(id: pane.id, title: title, subtitle: subtitle, kind: kind, window: window, tab: tabIndex,
                               pane: paneIndex, location: windows > 1 ? "Window \(window) › " + place : place,
                               isCurrent: pane.id == current)
    }
}
