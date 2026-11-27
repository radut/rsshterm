/// The remote pointer's shape as the server sends it (RDP pointer updates, the VNC Cursor pseudo-encoding): RGBA
/// pixels, row-major from the top, straight alpha, and the hotspot (the pixel that clicks).
public struct RemoteCursor: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let hotX: Int
    public let hotY: Int
    public let rgba: [UInt8]

    /// Nil when `rgba` is not `width * height * 4` bytes. The hotspot is kept inside the image.
    public init?(width: Int, height: Int, hotX: Int, hotY: Int, rgba: [UInt8]) {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.hotX = min(max(hotX, 0), width - 1)
        self.hotY = min(max(hotY, 0), height - 1)
        self.rgba = rgba
    }

    private init() {
        width = 0
        height = 0
        hotX = 0
        hotY = 0
        rgba = []
    }

    /// The server hid the pointer (RDP Pointer_SetNull, an empty VNC cursor).
    public static let hidden = RemoteCursor()
    public var isHidden: Bool { width == 0 }

    public func alpha(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return rgba[(y * width + x) * 4 + 3]
    }

    /// A standard arrow for servers that send no shape (and RDP's "system default" pointer): white with a black
    /// outline, tip at the hotspot.
    public static let arrow: RemoteCursor = {
        let art = [
            "X           ",
            "XX          ",
            "X.X         ",
            "X..X        ",
            "X...X       ",
            "X....X      ",
            "X.....X     ",
            "X......X    ",
            "X.......X   ",
            "X........X  ",
            "X.........X ",
            "X......XXXXX",
            "X...X..X    ",
            "X..XX..X    ",
            "X.X  X..X   ",
            "XX   X..X   ",
            "X     X..X  ",
            "      X..X  ",
            "       XX   ",
        ]
        let pixels = art.flatMap { row in
            row.flatMap { c -> [UInt8] in
                switch c {
                case "X": [0, 0, 0, 255]
                case ".": [255, 255, 255, 255]
                default: [0, 0, 0, 0]
                }
            }
        }
        return RemoteCursor(width: 12, height: art.count, hotX: 0, hotY: 0, rgba: pixels)!
    }()
}
