import RSSHKit
import Testing
@testable import RSSHVNC

@Suite struct RemoteKeyStrokesTests {
    typealias S = RemoteKeyStrokes.Stroke

    @Test func aPlainKeyIsPressedAndReleased() {
        let (strokes, latch) = RemoteKeyStrokes.strokes(for: .key(.escape), latch: ModifierLatch())
        #expect(strokes == [S(X11Keysym.escape, down: true), S(X11Keysym.escape, down: false)])
        #expect(latch == ModifierLatch())
    }

    @Test func aLatchedCtrlWrapsTheNextKeyThenReleases() {
        let ctrl = ModifierLatch().tapped(.ctrl)
        #expect(RemoteKeyStrokes.strokes(for: .latch(.ctrl), latch: ModifierLatch()).strokes.isEmpty)
        let (strokes, after) = RemoteKeyStrokes.strokes(for: .text("c"), latch: ctrl)
        #expect(strokes == [S(X11Keysym.controlLeft, down: true), S(0x63, down: true), S(0x63, down: false),
                            S(X11Keysym.controlLeft, down: false)])
        #expect(after.active.isEmpty)
        // Locked stays.
        let locked = ctrl.tapped(.ctrl)
        #expect(RemoteKeyStrokes.strokes(for: .key(.tab), latch: locked).latch.active == .ctrl)
    }

    @Test func metaAndComboModifiersAreHeldInOrder() {
        let (strokes, _) = RemoteKeyStrokes.strokes(for: .combo(.character("c"), .ctrl), latch: ModifierLatch().tapped(.alt),
                                                    meta: true)
        #expect(strokes.map(\.keysym) == [X11Keysym.controlLeft, X11Keysym.altLeft, X11Keysym.metaLeft, 0x63, 0x63,
                                          X11Keysym.metaLeft, X11Keysym.altLeft, X11Keysym.controlLeft])
        #expect(strokes.map(\.down) == [true, true, true, true, false, false, false, false])
    }

    @Test func functionAndNavigationKeysMap() {
        #expect(RemoteKeyStrokes.keysym(for: .function(5)) == X11Keysym.function(5))
        #expect(RemoteKeyStrokes.keysym(for: .pageDown) == X11Keysym.pageDown)
        #expect(RemoteKeyStrokes.keysym(for: .enter) == X11Keysym.returnKey)
    }

    @Test func wordEditingUsesDesktopKeys() {
        let left = RemoteKeyStrokes.strokes(for: .wordEdit(.wordLeft), latch: ModifierLatch()).strokes
        #expect(left.map(\.keysym) == [X11Keysym.controlLeft, X11Keysym.left, X11Keysym.left, X11Keysym.controlLeft])
        let toStart = RemoteKeyStrokes.strokes(for: .wordEdit(.deleteToLineStart), latch: ModifierLatch()).strokes
        #expect(toStart.map(\.keysym) == [X11Keysym.shiftLeft, X11Keysym.home, X11Keysym.home, X11Keysym.shiftLeft,
                                          X11Keysym.backspace, X11Keysym.backspace])
    }

    @Test func pasteAndPagingAreTheAppsAndKeepTheLatch() {
        let ctrl = ModifierLatch().tapped(.ctrl)
        #expect(RemoteKeyStrokes.strokes(for: .paste, latch: ctrl) == ([], ctrl))
        #expect(RemoteKeyStrokes.strokes(for: .morePages, latch: ctrl).latch == ctrl)
    }
}
