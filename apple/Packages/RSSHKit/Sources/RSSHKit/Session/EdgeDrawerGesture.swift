import Foundation

/// The arithmetic of the left-edge sessions drawer, kept apart from the UI so it can be tested: where a drag may
/// start, how far the drawer follows the finger and whether a release leaves it open.
public enum EdgeDrawerGesture {
    /// A drag opens the drawer only when it starts this close to the left edge (points).
    public static let edgeZone = 20.0
    public static let widthFraction = 0.8
    public static let maxWidth = 360.0
    /// A flick at least this fast (points per second) decides on its direction alone.
    public static let flickVelocity = 500.0

    /// About 80% of the screen, never wider than `maxWidth`.
    public static func drawerWidth(containerWidth: Double) -> Double {
        min(maxWidth, max(0, containerWidth * widthFraction))
    }

    /// `x` is where the touch went down, from the left edge of the window.
    public static func startsInEdgeZone(x: Double) -> Bool {
        x >= 0 && x <= edgeZone
    }

    /// How much of the drawer shows while the finger has moved `translation` points to the right.
    public static func revealed(translation: Double, width: Double, startedOpen: Bool) -> Double {
        let start = startedOpen ? width : 0
        return min(max(start + translation, 0), max(width, 0))
    }

    /// 0 (closed) to 1 (open), for the dimming behind the drawer.
    public static func progress(revealed: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(revealed / width, 0), 1)
    }

    /// True when the drawer should end open after the finger lifts: a fast flick goes its way, otherwise the drawer
    /// stays open once more than half of it shows.
    public static func settlesOpen(translation: Double, velocity: Double, width: Double, startedOpen: Bool) -> Bool {
        if velocity >= flickVelocity { return true }
        if velocity <= -flickVelocity { return false }
        return revealed(translation: translation, width: width, startedOpen: startedOpen) > width / 2
    }
}
