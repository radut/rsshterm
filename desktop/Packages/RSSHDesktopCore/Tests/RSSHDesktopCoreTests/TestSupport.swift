import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// SSH wire reading for tests (RSSHKit's reader is internal to it).
struct WireReader {
    private var bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw CocoaError(.coderReadCorrupt) }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint32() throws -> UInt32 {
        guard bytes.count - offset >= 4 else { throw CocoaError(.coderReadCorrupt) }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() throws -> Data {
        let length = Int(try uint32())
        guard bytes.count - offset >= length else { throw CocoaError(.coderReadCorrupt) }
        defer { offset += length }
        return Data(bytes[offset..<offset + length])
    }

    mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }
}

func wireString(_ data: Data) -> Data {
    var out = Data()
    let n = UInt32(data.count)
    out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
    out.append(data)
    return out
}

func wireUInt32(_ n: UInt32) -> Data {
    Data([UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
}

/// A fresh directory under /tmp (short, so socket paths fit sun_path); removed by `cleanup()`.
struct TempDir {
    let path: String

    init() throws {
        var template = Array("/tmp/rssh-test-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
        path = String(cString: made)
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: path) }
}

/// Runs a program and returns (status, stdout+stderr).
@discardableResult
func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, input: Data? = nil)
    throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    let stdin = Pipe()
    process.standardInput = stdin
    try process.run()
    if let input { stdin.fileHandleForWriting.write(input) }
    try stdin.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func closeDescriptor(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}
