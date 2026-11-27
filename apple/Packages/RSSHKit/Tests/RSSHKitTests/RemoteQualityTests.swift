import Foundation
import Testing
@testable import RSSHKit

@Suite struct RemoteQualityTests {
    @Test func autoIsTheDefaultAndIsNotWritten() throws {
        let desktop = RemoteDesktop(name: "W", kind: .rdp, host: "h")
        #expect(desktop.quality == .auto)
        let json = String(decoding: try JSONEncoder().encode(desktop), as: UTF8.self)
        #expect(!json.contains("quality"))
    }

    @Test func aPickedQualityIsSavedAndAnUnknownOneReadsAsAuto() throws {
        var desktop = RemoteDesktop(name: "W", kind: .rdp, host: "h")
        desktop.quality = .lowBandwidth
        let decoded = try JSONDecoder().decode(RemoteDesktop.self, from: try JSONEncoder().encode(desktop))
        #expect(decoded.quality == .lowBandwidth)
        let newer = #"{"id":"6D3F0E2A-1B7C-4C1E-9F51-0A0B0C0D0E0F","name":"N","kind":"rdp","host":"h","quality":"ultra"}"#
        #expect(try JSONDecoder().decode(RemoteDesktop.self, from: Data(newer.utf8)).quality == .auto)
    }

    @Test func autoLetsTheNetworkDecide() {
        let p = RDPQualityProfile(.auto)
        #expect(p.networkAutoDetect)
        #expect(p.connectionType == RDPQualityProfile.ConnectionType.autoDetect)
        #expect(p.colorDepth == 32)
        #expect(p.remoteFX)
    }

    @Test func highTurnsEverythingOn() {
        let p = RDPQualityProfile(.high)
        #expect(p.colorDepth == 32 && p.remoteFX && p.connectionType == RDPQualityProfile.ConnectionType.lan)
        #expect(p.wallpaper && p.themes && p.menuAnimations && p.fullWindowDrag && p.fontSmoothing && p.desktopComposition)
        #expect(!p.networkAutoDetect)
    }

    @Test func balancedKeepsColourButDropsTheExtras() {
        let p = RDPQualityProfile(.balanced)
        #expect(p.colorDepth == 32 && p.remoteFX && p.fontSmoothing && p.themes)
        #expect(!p.wallpaper && !p.menuAnimations && !p.fullWindowDrag && !p.desktopComposition)
        #expect(p.connectionType == RDPQualityProfile.ConnectionType.broadbandHigh)
    }

    @Test func lowBandwidthIs16BitWithNothingExtra() {
        let p = RDPQualityProfile(.lowBandwidth)
        #expect(p.colorDepth == 16 && !p.remoteFX)
        #expect(!p.wallpaper && !p.themes && !p.menuAnimations && !p.fullWindowDrag && !p.fontSmoothing
                && !p.desktopComposition)
        #expect(p.connectionType == RDPQualityProfile.ConnectionType.modem && p.compression)
    }

    @Test func everyQualityHasATitleAndChangingItReconnects() {
        #expect(RemoteDesktop.Quality.allCases.map(\.title) == ["Auto", "High", "Balanced", "Low bandwidth"])
        #expect(RemoteDesktop.Quality.allCases.allSatisfy { $0.needsReconnect })
    }
}

@Suite struct RemoteOrientationTests {
    @Test func landscapeIsTheDefaultAndIsNotWritten() throws {
        let desktop = RemoteDesktop(name: "W", kind: .rdp, host: "h")
        #expect(desktop.orientation == .landscape)
        #expect(!String(decoding: try JSONEncoder().encode(desktop), as: UTF8.self).contains("orientation"))
    }

    @Test func aPickedOrientationIsSaved() throws {
        var desktop = RemoteDesktop(name: "W", kind: .vnc, host: "h")
        desktop.orientation = .followDevice
        let decoded = try JSONDecoder().decode(RemoteDesktop.self, from: try JSONEncoder().encode(desktop))
        #expect(decoded.orientation == .followDevice)
        #expect(RemoteDesktop.Orientation.allCases.map(\.title) == ["Landscape", "Portrait", "Follow device"])
    }

    @Test func theRotateButtonSwapsLandscapeAndPortrait() {
        #expect(RemoteDesktop.Orientation.landscape.toggled == .portrait)
        #expect(RemoteDesktop.Orientation.portrait.toggled == .landscape)
        #expect(RemoteDesktop.Orientation.followDevice.toggled == .landscape)
    }
}
