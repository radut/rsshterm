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

@Suite struct RemoteModifierLatchTests {
    @Test func aLatchedShiftWrapsTheNextKeyThenReleases() {
        let shift = RemoteKeyStrokes.strokes(for: .latch(.shift), latch: ModifierLatch()).latch
        #expect(shift.active == .shift)
        let (strokes, after) = RemoteKeyStrokes.strokes(for: .key(.tab), latch: shift)
        #expect(strokes == [.init(X11Keysym.shiftLeft, down: true), .init(X11Keysym.tab, down: true),
                            .init(X11Keysym.tab, down: false), .init(X11Keysym.shiftLeft, down: false)])
        #expect(after.active.isEmpty)
    }

    @Test func aLatchedAltWrapsTypedText() {
        let alt = ModifierLatch().tapped(.alt)
        let (strokes, _) = RemoteKeyStrokes.strokes(for: .text("f"), latch: alt)
        #expect(strokes.first == .init(X11Keysym.altLeft, down: true))
        #expect(strokes.last == .init(X11Keysym.altLeft, down: false))
        #expect(strokes.count == 4)
    }

    @Test func shiftAltAndTheWindowsKeyTogether() {
        let latch = ModifierLatch().tapped(.shift).tapped(.alt)
        let (strokes, _) = RemoteKeyStrokes.strokes(for: .key(.left), latch: latch, meta: true)
        #expect(strokes.prefix(3).map(\.keysym) == [X11Keysym.altLeft, X11Keysym.shiftLeft, X11Keysym.metaLeft])
        #expect(strokes.suffix(3).map(\.keysym) == [X11Keysym.metaLeft, X11Keysym.shiftLeft, X11Keysym.altLeft])
    }

    @Test func theWindowsKeyAloneAndCtrlAltDel() {
        #expect(RemoteKeyStrokes.metaTap == [.init(X11Keysym.metaLeft, down: true), .init(X11Keysym.metaLeft, down: false)])
        #expect(RemoteKeyStrokes.ctrlAltDelete.map(\.keysym)
                == [X11Keysym.controlLeft, X11Keysym.altLeft, X11Keysym.delete,
                    X11Keysym.delete, X11Keysym.altLeft, X11Keysym.controlLeft])
        #expect(RemoteKeyStrokes.ctrlAltDelete.map(\.down) == [true, true, true, false, false, false])
    }
}

@Suite struct RemoteCursorTests {
    @Test func theFallbackArrowHasItsTipAtTheHotspot() {
        let arrow = RemoteCursor.arrow
        #expect(arrow.hotX == 0 && arrow.hotY == 0)
        #expect(arrow.width >= 10 && arrow.height >= 16)
        #expect(arrow.rgba.count == arrow.width * arrow.height * 4)
        #expect(arrow.alpha(x: 0, y: 0) == 255, "the tip is drawn")
        #expect(arrow.alpha(x: arrow.width - 1, y: 0) == 0, "the top right is transparent")
        #expect(!arrow.isHidden)
    }

    @Test func hiddenHasNoPixels() {
        #expect(RemoteCursor.hidden.isHidden)
        #expect(RemoteCursor.hidden.rgba.isEmpty)
    }

    @Test func aVNCCursorKeepsItsPixelsAndHotspot() {
        // 2x1: opaque red, transparent.
        let cursor = RemoteCursor(width: 2, height: 1, hotX: 1, hotY: 0, rgba: [255, 0, 0, 255, 0, 0, 0, 0])
        #expect(cursor?.alpha(x: 0, y: 0) == 255)
        #expect(cursor?.alpha(x: 1, y: 0) == 0)
        #expect(RemoteCursor(width: 2, height: 2, hotX: 0, hotY: 0, rgba: [0, 0, 0, 0]) == nil, "too few bytes")
        #expect(RemoteCursor(width: 2, height: 1, hotX: 5, hotY: 0, rgba: [UInt8](repeating: 0, count: 8))?.hotX == 1,
                "the hotspot stays inside")
    }
}

@Suite struct VNCQualityTests {
    @Test func lowBandwidthIs16BitAndTightFirst() {
        let o = VNCSession.Options(quality: .lowBandwidth)
        #expect(o.colorDepth == 16)
        #expect(o.encodings.first == .tight)
    }

    @Test func highIsLosslessFirst() {
        let o = VNCSession.Options(quality: .high)
        #expect(o.colorDepth == 24)
        #expect(o.encodings.first == .zrle)
    }

    @Test func autoAndBalancedKeepTheDefaults() {
        #expect(VNCSession.Options(quality: .auto).encodings == VNCSession.Options().encodings)
        #expect(VNCSession.Options(quality: .balanced).colorDepth == 24)
    }
}
