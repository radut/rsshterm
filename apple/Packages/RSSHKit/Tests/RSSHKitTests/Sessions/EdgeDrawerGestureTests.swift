import Testing
@testable import RSSHKit

@Suite struct EdgeDrawerGestureTests {
    @Test func drawerWidthIsEightyPercentCappedAt360() {
        #expect(EdgeDrawerGesture.drawerWidth(containerWidth: 390) == 312)
        #expect(EdgeDrawerGesture.drawerWidth(containerWidth: 1024) == 360)
        #expect(EdgeDrawerGesture.drawerWidth(containerWidth: -5) == 0)
    }

    @Test(arguments: [0.0, 5, 20])
    func startsInsideTheEdgeZone(_ x: Double) {
        #expect(EdgeDrawerGesture.startsInEdgeZone(x: x))
    }

    @Test(arguments: [-1.0, 20.5, 60, 200])
    func startsOutsideTheEdgeZone(_ x: Double) {
        #expect(!EdgeDrawerGesture.startsInEdgeZone(x: x))
    }

    @Test func revealedFollowsTheFingerAndStaysInside() {
        #expect(EdgeDrawerGesture.revealed(translation: 100, width: 300, startedOpen: false) == 100)
        #expect(EdgeDrawerGesture.revealed(translation: 500, width: 300, startedOpen: false) == 300)
        #expect(EdgeDrawerGesture.revealed(translation: -40, width: 300, startedOpen: false) == 0)
        #expect(EdgeDrawerGesture.revealed(translation: -100, width: 300, startedOpen: true) == 200)
        #expect(EdgeDrawerGesture.revealed(translation: 50, width: 300, startedOpen: true) == 300)
    }

    @Test func progressIsAFraction() {
        #expect(EdgeDrawerGesture.progress(revealed: 150, width: 300) == 0.5)
        #expect(EdgeDrawerGesture.progress(revealed: 10, width: 0) == 0)
    }

    @Test func slowReleasePastHalfOpens() {
        #expect(EdgeDrawerGesture.settlesOpen(translation: 151, velocity: 0, width: 300, startedOpen: false))
        #expect(!EdgeDrawerGesture.settlesOpen(translation: 149, velocity: 0, width: 300, startedOpen: false))
    }

    @Test func fastFlickDecidesWhateverTheDistance() {
        #expect(EdgeDrawerGesture.settlesOpen(translation: 30, velocity: 900, width: 300, startedOpen: false))
        #expect(!EdgeDrawerGesture.settlesOpen(translation: 250, velocity: -900, width: 300, startedOpen: false))
    }

    @Test func draggingAnOpenDrawerLeftCloses() {
        #expect(!EdgeDrawerGesture.settlesOpen(translation: -200, velocity: 0, width: 300, startedOpen: true))
        #expect(EdgeDrawerGesture.settlesOpen(translation: -100, velocity: 0, width: 300, startedOpen: true))
        #expect(!EdgeDrawerGesture.settlesOpen(translation: -20, velocity: -800, width: 300, startedOpen: true))
    }
}
