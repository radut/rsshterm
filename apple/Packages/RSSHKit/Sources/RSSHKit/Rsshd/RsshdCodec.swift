import Foundation

/// Why a line could not be read.
public enum RsshdCodecError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion(Int)
    case lineTooLong
}

/// One line from the daemon.
public enum RsshdIncoming: Equatable, Sendable {
    /// The answer to request `id`: the raw `result` object, or the error.
    case reply(id: Int, result: Result<Data, RsshdError>)
    /// An unsolicited event (only after `subscribe`).
    case event(name: String, data: Data)
}

/// JSON lines of PROTOCOL.md: one object per line, `"v":1` in every message, unknown fields ignored.
public enum RsshdCodec {
    private struct Request<Args: Encodable>: Encodable {
        var v = RsshdProtocol.version
        var id: Int
        var op: String
        var args: Args
    }

    /// The request as one line, newline included.
    public static func request(id: Int, op: String, args: some Encodable) throws -> Data {
        var data = try JSONEncoder().encode(Request(id: id, op: op, args: args))
        data.append(0x0A)
        return data
    }

    public static func decode(line: Data) throws(RsshdCodecError) -> RsshdIncoming {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { throw .malformed }
        let version = (object["v"] as? NSNumber)?.intValue ?? 0
        guard version == RsshdProtocol.version else { throw .unsupportedVersion(version) }
        if let name = object["event"] as? String {
            return .event(name: name, data: raw(object["data"]))
        }
        guard let id = (object["id"] as? NSNumber)?.intValue else { throw .malformed }
        if (object["ok"] as? Bool) == true {
            return .reply(id: id, result: .success(raw(object["result"])))
        }
        let error = (try? JSONDecoder().decode(RsshdError.self, from: raw(object["error"])))
            ?? RsshdError(code: .badRequest, message: "reply without an error")
        return .reply(id: id, result: .failure(error))
    }

    /// A reply's `result` as a typed value.
    public static func decodeResult<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private static func raw(_ value: Any?) -> Data {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return Data("{}".utf8) }
        return data
    }
}

/// Splits a byte stream into lines; a line longer than 1 MiB is an error (the protocol closes the connection).
public struct RsshdLineBuffer: Sendable {
    private var pending: [UInt8] = []
    private let limit: Int

    public init(limit: Int = RsshdProtocol.maxLineBytes) { self.limit = limit }

    /// The complete lines in `bytes` (with what was held before), without their newline; blank lines are skipped.
    public mutating func append(_ bytes: some Sequence<UInt8>) throws(RsshdCodecError) -> [Data] {
        pending.append(contentsOf: bytes)
        var lines: [Data] = []
        var start = 0
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            var line = pending[start..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if line.count > limit { throw .lineTooLong }
            if !line.isEmpty { lines.append(Data(line)) }
            start = newline + 1
        }
        pending.removeFirst(start)
        if pending.count > limit { throw .lineTooLong }
        return lines
    }
}
