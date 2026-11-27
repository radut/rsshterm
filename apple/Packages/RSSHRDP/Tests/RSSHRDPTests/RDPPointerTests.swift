import RSSHVNC
import Testing
@testable import RSSHRDP

/// RDP pointer bitmaps (MS-RDPBCGR 2.2.9.1.1.4.4) to RGBA: XOR + AND masks, bottom-up rows, word-padded scanlines.
@Suite struct RDPPointerTests {
    @Test func a32BitPointerKeepsItsAlphaAndComesTopDown() throws {
        // 1x2, 32 bpp BGRA, stored bottom-up: first row in the data is the bottom one.
        let bottom: [UInt8] = [0, 0, 255, 255]   // opaque red (B, G, R, A)
        let top: [UInt8] = [255, 0, 0, 128]      // half-transparent blue
        let and: [UInt8] = [0, 0, 0, 0]          // 1 bpp, two scanlines of 2 bytes
        let cursor = try #require(RDPPointer.cursor(width: 1, height: 2, hotX: 0, hotY: 1, xorBpp: 32,
                                                    xorMask: bottom + top, andMask: and))
        #expect(cursor.hotY == 1)
        #expect(Array(cursor.rgba[0..<4]) == [0, 0, 255, 128], "top: blue, alpha kept")
        #expect(Array(cursor.rgba[4..<8]) == [255, 0, 0, 255], "bottom: red")
    }

    @Test func aMonochromePointerUsesTheAndMaskForTransparency() throws {
        // 2x1, 1 bpp. XOR bits 1 0 (white, black), AND bits 0 1 (opaque, transparent): white then transparent.
        let xor: [UInt8] = [0b1000_0000, 0]
        let and: [UInt8] = [0b0100_0000, 0]
        let cursor = try #require(RDPPointer.cursor(width: 2, height: 1, hotX: 0, hotY: 0, xorBpp: 1,
                                                    xorMask: xor, andMask: and))
        #expect(cursor.alpha(x: 0, y: 0) == 255)
        #expect(Array(cursor.rgba[0..<3]) == [255, 255, 255])
        #expect(cursor.alpha(x: 1, y: 0) == 0)
    }

    @Test func nonsenseSizesGiveNoCursor() {
        #expect(RDPPointer.cursor(width: 0, height: 4, hotX: 0, hotY: 0, xorBpp: 32, xorMask: [], andMask: []) == nil)
        #expect(RDPPointer.cursor(width: 400, height: 400, hotX: 0, hotY: 0, xorBpp: 32, xorMask: [], andMask: []) == nil)
        #expect(RDPPointer.cursor(width: 4, height: 4, hotX: 0, hotY: 0, xorBpp: 32, xorMask: [1, 2], andMask: []) == nil,
                "a short XOR mask")
    }
}
