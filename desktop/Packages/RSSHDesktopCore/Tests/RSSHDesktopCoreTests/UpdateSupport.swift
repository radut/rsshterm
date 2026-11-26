import Crypto
import Foundation
import Synchronization
@testable import RSSHDesktopCore

/// Serves fixed bodies by URL; records downloads.
final class FakeTransport: UpdateTransport, Sendable {
    private let bodies: Mutex<[String: Data]>

    init(_ bodies: [String: Data] = [:]) { self.bodies = Mutex(bodies) }

    func set(_ url: String, _ data: Data?) { bodies.withLock { $0[url] = data } }

    func data(from url: URL) async throws -> Data {
        guard let body = bodies.withLock({ $0[url.absoluteString] }) else { throw UpdateError.transport("404 \(url)") }
        return body
    }

    func download(_ url: URL, to file: URL) async throws {
        try await data(from: url).write(to: file)
    }
}

/// Records every call; answers from `handler` (default: status 0).
final class FakeRunner: ProcessRunner, Sendable {
    typealias Handler = @Sendable (String, [String]) throws -> ProcessOutput
    let calls = Mutex<[[String]]>([])
    let detached = Mutex<[[String]]>([])
    private let handler: Handler

    init(handler: @escaping Handler = { _, _ in ProcessOutput(status: 0, output: "") }) { self.handler = handler }

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessOutput {
        calls.withLock { $0.append([executable] + arguments) }
        return try handler(executable, arguments)
    }

    func launchDetached(_ executable: String, _ arguments: [String]) throws {
        detached.withLock { $0.append([executable] + arguments) }
    }
}

struct SignedFeed {
    static let base = "https://updates.example.test"
    let key = Curve25519.Signing.PrivateKey()
    let transport = FakeTransport()

    var trust: UpdateTrust { UpdateTrust(publicKeys: [key.publicKey]) }
    var checker: UpdateChecker {
        UpdateChecker(baseURL: URL(string: Self.base)!, transport: transport, trust: trust)
    }

    func publish(_ json: String, signature: Data? = nil) throws {
        let data = Data(json.utf8)
        transport.set("\(Self.base)/desktop/latest.json", data)
        let sig = try signature ?? key.signature(for: data)
        transport.set("\(Self.base)/desktop/latest.json.sig", Data(sig.base64EncodedString().utf8))
    }

    /// Serves `payload` at an asset URL and publishes a manifest for `version` pointing at it.
    func publish(version: String, assetKey: String, fileName: String, payload: Data, sha256: String? = nil) throws {
        let url = "\(Self.base)/desktop/\(version)/\(fileName)"
        transport.set(url, payload)
        let digest = sha256 ?? SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try publish(#"{"version":"\#(version)","notes":"New","assets":{"\#(assetKey)":{"url":"\#(url)","sha256":"\#(digest)"}}}"#)
    }
}
