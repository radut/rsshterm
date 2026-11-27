/// What a remote desktop's Quality asks of an RDP server (FreeRDP settings), from Auto (the network decides) to Low
/// bandwidth. Negotiated when connecting, so a change reconnects. The graphics pipeline (GFX, AVC420/444) is not used:
/// this app's FreeRDP has no H.264; the classic pipeline with the RemoteFX codec (when the server offers it) instead.
public struct RDPQualityProfile: Equatable, Sendable {
    /// MS-RDPBCGR connection types (FreeRDP's CONNECTION_TYPE_*).
    public enum ConnectionType {
        public static let modem: UInt32 = 1
        public static let broadbandHigh: UInt32 = 4
        public static let lan: UInt32 = 6
        public static let autoDetect: UInt32 = 7
    }

    public var colorDepth: UInt32
    public var connectionType: UInt32
    public var networkAutoDetect: Bool
    /// Offer the RemoteFX codec (surface bits); otherwise plain bitmap updates.
    public var remoteFX: Bool
    public var wallpaper: Bool
    public var themes: Bool
    public var menuAnimations: Bool
    public var fullWindowDrag: Bool
    public var fontSmoothing: Bool
    public var desktopComposition: Bool
    /// Bulk compression of the RDP stream.
    public var compression: Bool

    public init(_ quality: RemoteDesktop.Quality) {
        switch quality {
        case .auto:
            self.init(colorDepth: 32, connectionType: ConnectionType.autoDetect, networkAutoDetect: true,
                      remoteFX: true, all: true)
            wallpaper = false   // auto-detect turns the extras back on when the network is fast
            desktopComposition = false
        case .high:
            self.init(colorDepth: 32, connectionType: ConnectionType.lan, networkAutoDetect: false,
                      remoteFX: true, all: true)
        case .balanced:
            self.init(colorDepth: 32, connectionType: ConnectionType.broadbandHigh, networkAutoDetect: false,
                      remoteFX: true, all: false)
            themes = true
            fontSmoothing = true
        case .lowBandwidth:
            self.init(colorDepth: 16, connectionType: ConnectionType.modem, networkAutoDetect: false,
                      remoteFX: false, all: false)
        }
    }

    private init(colorDepth: UInt32, connectionType: UInt32, networkAutoDetect: Bool, remoteFX: Bool, all: Bool) {
        self.colorDepth = colorDepth
        self.connectionType = connectionType
        self.networkAutoDetect = networkAutoDetect
        self.remoteFX = remoteFX
        wallpaper = all
        themes = all
        menuAnimations = all
        fullWindowDrag = all
        fontSmoothing = all
        desktopComposition = all
        compression = true
    }
}
