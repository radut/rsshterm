import CRSSHRDP
import RSSHVNC

/// RDP pointer bitmaps to a `RemoteCursor` (the session does this for every pointer update; here for tests and
/// any caller that has the raw masks).
public enum RDPPointer {
    /// `xorMask` and `andMask` as on the wire (bottom-up rows, each padded to an even number of bytes); `xorBpp` 1, 16,
    /// 24 or 32. Nil for sizes over 384 or masks shorter than the size needs.
    public static func cursor(width: Int, height: Int, hotX: Int, hotY: Int, xorBpp: Int, xorMask: [UInt8],
                              andMask: [UInt8]) -> RemoteCursor? {
        guard (1...384).contains(width), (1...384).contains(height), [1, 16, 24, 32].contains(xorBpp) else { return nil }
        func stride(_ bpp: Int) -> Int { ((width * bpp + 15) / 16) * 2 }
        guard xorMask.count >= stride(xorBpp) * height,
              andMask.isEmpty || andMask.count >= stride(1) * height else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ok = rgba.withUnsafeMutableBufferPointer { dst in
            xorMask.withUnsafeBufferPointer { xor in
                andMask.withUnsafeBufferPointer { and in
                    rssh_rdp_pointer_rgba(dst.baseAddress, UInt32(width), UInt32(height), UInt32(xorBpp),
                                          xor.baseAddress, UInt32(xor.count), andMask.isEmpty ? nil : and.baseAddress,
                                          UInt32(and.count))
                }
            }
        }
        guard ok == 1 else { return nil }
        return RemoteCursor(width: width, height: height, hotX: hotX, hotY: hotY, rgba: rgba)
    }
}
