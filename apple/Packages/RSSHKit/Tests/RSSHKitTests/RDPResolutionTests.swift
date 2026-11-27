import Foundation
import Testing
@testable import RSSHKit

@Suite struct RDPDisplaySizeTests {
    // iPhone 16 Pro: 402x874 points at 3x.
    let portrait = (width: 402.0, height: 874.0)
    let landscape = (width: 874.0, height: 402.0)

    @Test func matchingKeepsTheOrientationAndTwiceThePoints() {
        #expect(RDPDisplaySize.matching(width: landscape.width, height: landscape.height, scale: 3) == RDPDisplaySize(width: 1748, height: 804))
        #expect(RDPDisplaySize.matching(width: portrait.width, height: portrait.height, scale: 3) == RDPDisplaySize(width: 804, height: 1748))
        #expect(RDPDisplaySize.matching(width: portrait.width, height: portrait.height, scale: 3).isLandscape == false)
    }

    @Test func matchingAnIPadStaysWithinWhatServersTakeAndKeepsTheAspect() {
        // 13" iPad 1376x1032 at 2x would be 2752x2064: scaled down to a long side of 2560.
        let size = RDPDisplaySize.matching(width: 1376, height: 1032, scale: 2)
        #expect(size == RDPDisplaySize(width: 2560, height: 1920))
        let tall = RDPDisplaySize.matching(width: 1032, height: 1376, scale: 2)
        #expect(tall == RDPDisplaySize(width: 1920, height: 2560))
    }

    @Test func matchingASmallScreenGrowsToAUsableDesktopAndStaysEven() {
        let size = RDPDisplaySize.matching(width: 501, height: 301, scale: 1)
        #expect(size.height >= 600)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
        #expect(abs(Double(size.width) / Double(size.height) - 501.0 / 301.0) < 0.02)
    }

    @Test func choicesFollowTheOrientationAndTheScreensAspect() {
        let wide = RDPDisplaySize.choices(width: landscape.width, height: landscape.height, scale: 3)
        #expect(wide.count == 5)
        let allLandscape = wide.allSatisfy { $0.isLandscape }
        #expect(allLandscape)
        #expect(wide == wide.sorted { $0.width < $1.width })
        for size in wide {
            #expect(size.width % 2 == 0 && size.height % 2 == 0)
            #expect(abs(Double(size.width) / Double(size.height) - 874.0 / 402.0) < 0.02)
        }
        #expect(wide.first == RDPDisplaySize(width: 1092, height: 502))
        #expect(wide.last == RDPDisplaySize(width: 1966, height: 904))

        let tall = RDPDisplaySize.choices(width: portrait.width, height: portrait.height, scale: 3)
        let allPortrait = tall.allSatisfy { !$0.isLandscape }
        #expect(allPortrait)
        #expect(tall.map(\.rotated) == wide)
    }

    @Test func customSizesAreCheckedAndMadeEven() {
        #expect(RDPDisplaySize.custom(width: 1921, height: 1081) == RDPDisplaySize(width: 1920, height: 1080))
        #expect(RDPDisplaySize.custom(width: 100, height: 800) == nil)
        #expect(RDPDisplaySize.custom(width: 1024, height: 9000) == nil)
        #expect(RDPDisplaySize.parse("1280x720") == RDPDisplaySize(width: 1280, height: 720))
        #expect(RDPDisplaySize.parse(" 1280 × 720 ") == RDPDisplaySize(width: 1280, height: 720))
        #expect(RDPDisplaySize.parse("1280") == nil)
        #expect(RDPDisplaySize(width: 1280, height: 720).label == "1280 × 720")
    }
}

@Suite struct RDPResolutionTests {
    let landscape = (width: 874.0, height: 402.0)
    let portrait = (width: 402.0, height: 874.0)

    @Test func matchDeviceFollowsTheScreen() {
        #expect(RDPResolution.matchDevice.size(width: landscape.width, height: landscape.height, scale: 3) == RDPDisplaySize(width: 1748, height: 804))
        #expect(RDPResolution.matchDevice.size(width: portrait.width, height: portrait.height, scale: 3) == RDPDisplaySize(width: 804, height: 1748))
    }

    @Test func aFixedSizeTurnsWithThePhone() {
        let fixed = RDPResolution.fixed(RDPDisplaySize(width: 1600, height: 900))
        #expect(fixed.size(width: landscape.width, height: landscape.height, scale: 3) == RDPDisplaySize(width: 1600, height: 900))
        #expect(fixed.size(width: portrait.width, height: portrait.height, scale: 3) == RDPDisplaySize(width: 900, height: 1600))
    }

    @Test func savedInTheEntryAndOlderEntriesMatchTheDevice() throws {
        var desktop = RemoteDesktop(name: "Office", kind: .rdp, host: "10.0.0.5")
        #expect(desktop.resolution == .matchDevice)
        desktop.resolution = .fixed(RDPDisplaySize(width: 1920, height: 1080))
        let data = try JSONEncoder().encode(desktop)
        #expect(try JSONDecoder().decode(RemoteDesktop.self, from: data).resolution == desktop.resolution)

        let old = #"{"id":"6D3F0E2A-1B7C-4C1E-9F51-0A0B0C0D0E0F","name":"Old","kind":"rdp","host":"h","port":3389}"#
        #expect(try JSONDecoder().decode(RemoteDesktop.self, from: Data(old.utf8)).resolution == .matchDevice)
        // The default is not written, so older builds read the entry unchanged.
        let plain = try JSONEncoder().encode(RemoteDesktop(name: "P", kind: .rdp, host: "h"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("resolution"))
    }
}

@Suite struct RDPResizeDecisionTests {
    let current = RDPDisplaySize(width: 1748, height: 804)

    @Test func theSameSizeDoesNothing() {
        #expect(RDPResizeDecision.decide(current: current, wanted: current, canResizeLive: true) == .keep)
        // A server that rounds the size by a few pixels is not asked again.
        #expect(RDPResizeDecision.decide(current: RDPDisplaySize(width: 1744, height: 804), wanted: current,
                                         canResizeLive: false) == .keep)
    }

    @Test func turningThePhoneResizesLiveWhenTheServerCan() {
        let turned = current.rotated
        #expect(RDPResizeDecision.decide(current: current, wanted: turned, canResizeLive: true) == .resizeLive(turned))
    }

    @Test func otherwiseItReconnectsAtTheNewSize() {
        let turned = current.rotated
        #expect(RDPResizeDecision.decide(current: current, wanted: turned, canResizeLive: false) == .reconnect(turned))
    }
}
