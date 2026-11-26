import Crypto
import Foundation
import Testing
@testable import RSSHDesktopCore

@Suite struct SemanticVersionTests {
    @Test func parses() {
        #expect(SemanticVersion("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("v0.10.0")?.minor == 10)
        #expect(SemanticVersion("1.2.3-beta.1+build.5")?.prerelease == ["beta", "1"])
        #expect(SemanticVersion("1.2.3-beta.1+build.5")?.build == "build.5")
        for bad in ["", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "1.2.3-", "1.2.3-a..b", " 1 .2.3", "1.2.3+"] {
            #expect(SemanticVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func precedence() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"].map { SemanticVersion($0)! }
        for (a, b) in zip(ordered, ordered.dropFirst()) { #expect(a < b, "\(a) < \(b)") }
        #expect(SemanticVersion("1.0.0+a") == SemanticVersion("1.0.0+b"))
        #expect(SemanticVersion("1.10.0")! > SemanticVersion("1.9.9")!)
    }
}

@Suite struct UpdateCheckTests {
    @Test func newerVersionIsAvailable() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "1.3.0", assetKey: "linux-amd64", fileName: "a.tar.gz", payload: Data("x".utf8))
        let result = try await feed.checker.check(current: SemanticVersion("1.2.0")!, assetKey: "linux-amd64")
        guard case .available(let update) = result else { Issue.record("\(result)"); return }
        #expect(update.version == SemanticVersion("1.3.0"))
        #expect(update.notes == "New")
    }

    @Test func sameOrOlderIsUpToDate() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "1.2.0", assetKey: "linux-amd64", fileName: "a.tar.gz", payload: Data("x".utf8))
        #expect(try await feed.checker.check(current: SemanticVersion("1.2.0")!, assetKey: "linux-amd64")
            == .upToDate(latest: SemanticVersion("1.2.0")!))
        #expect(try await feed.checker.check(current: SemanticVersion("2.0.0")!, assetKey: "linux-amd64")
            == .upToDate(latest: SemanticVersion("1.2.0")!))
    }

    @Test func missingSignatureIsRefused() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "9.0.0", assetKey: "linux-amd64", fileName: "a", payload: Data())
        feed.transport.set("\(SignedFeed.base)/desktop/latest.json.sig", nil)
        await #expect(throws: UpdateError.unsigned) {
            try await feed.checker.check(current: SemanticVersion("1.0.0")!, assetKey: "linux-amd64")
        }
    }

    @Test func tamperedManifestIsRefusedBeforeParsing() async throws {
        let feed = SignedFeed()
        let good = #"{"version":"1.0.0","assets":{}}"#
        try feed.publish(good)
        // same signature, different bytes (even just whitespace)
        feed.transport.set("\(SignedFeed.base)/desktop/latest.json", Data((good + " ").utf8))
        await #expect(throws: UpdateError.badSignature) {
            try await feed.checker.check(current: SemanticVersion("0.1.0")!, assetKey: "linux-amd64")
        }
    }

    @Test func signatureFromAnotherKeyIsRefused() async throws {
        let feed = SignedFeed()
        let json = #"{"version":"2.0.0","assets":{}}"#
        try feed.publish(json, signature: try Curve25519.Signing.PrivateKey().signature(for: Data(json.utf8)))
        await #expect(throws: UpdateError.badSignature) {
            try await feed.checker.check(current: SemanticVersion("0.1.0")!, assetKey: "linux-amd64")
        }
    }

    @Test func noEmbeddedKeyTrustsNothing() async throws {
        let feed = SignedFeed()
        try feed.publish(#"{"version":"2.0.0","assets":{}}"#)
        let checker = UpdateChecker(baseURL: URL(string: SignedFeed.base)!, transport: feed.transport,
                                    trust: UpdateTrust(base64Keys: []))
        await #expect(throws: UpdateError.badSignature) {
            try await checker.check(current: SemanticVersion("0.1.0")!, assetKey: "linux-amd64")
        }
    }

    @Test func manifestValidation() async throws {
        let feed = SignedFeed()
        try feed.publish(#"{"version":"2.0.0","assets":{"linux-amd64":{"url":"http://x.test/a","sha256":"\#(String(repeating: "a", count: 64))"}}}"#)
        await #expect(throws: UpdateError.insecureURL("http://x.test/a")) {
            try await feed.checker.check(current: SemanticVersion("0.1.0")!, assetKey: "linux-amd64")
        }
        try feed.publish(#"{"version":"2.0.0","assets":{"linux-amd64":{"url":"https://x.test/a","sha256":"abc"}}}"#)
        await #expect(throws: UpdateError.badManifest("sha256 of linux-amd64")) {
            try await feed.checker.check(current: SemanticVersion("0.1.0")!, assetKey: "linux-amd64")
        }
        try feed.publish(#"{"version":"latest","assets":{}}"#)
        await #expect(throws: UpdateError.badManifest("version latest")) {
            try await feed.checker.check(current: SemanticVersion("0.1.0")!, assetKey: "linux-amd64")
        }
    }

    @Test func noAssetForThisPlatform() async throws {
        let feed = SignedFeed()
        try feed.publish(version: "3.0.0", assetKey: "macos-universal", fileName: "a.dmg", payload: Data())
        await #expect(throws: UpdateError.noAsset("linux-arm64")) {
            try await feed.checker.check(current: SemanticVersion("1.0.0")!, assetKey: "linux-arm64")
        }
    }

    @Test func downloadVerifiesSHA256() async throws {
        let feed = SignedFeed()
        let dir = try TempDir()
        defer { dir.cleanup() }
        try feed.publish(version: "1.1.0", assetKey: "linux-amd64", fileName: "a.tar.gz", payload: Data("payload".utf8))
        guard case .available(let update) = try await feed.checker.check(current: SemanticVersion("1.0.0")!,
                                                                            assetKey: "linux-amd64") else { return }
        let file = try await feed.checker.download(update, into: URL(fileURLWithPath: dir.path))
        #expect(try Data(contentsOf: file) == Data("payload".utf8))

        // the server swaps the file after publishing
        feed.transport.set(update.asset.url, Data("evil".utf8))
        await #expect(throws: UpdateError.self) {
            _ = try await feed.checker.download(update, into: URL(fileURLWithPath: dir.path))
        }
        #expect(!FileManager.default.fileExists(atPath: file.path)) // the bad download is deleted
    }

    @Test func platformKeys() {
        #expect(UpdatePlatformKey.key(platform: .linux, architecture: "x86_64") == "linux-amd64")
        #expect(UpdatePlatformKey.key(platform: .linux, architecture: "aarch64") == "linux-arm64")
        #expect(UpdatePlatformKey.key(platform: .macOS, architecture: "arm64") == "macos-universal")
    }

    @Test func defaultURLs() {
        let checker = UpdateChecker(transport: FakeTransport(), trust: UpdateTrust(base64Keys: []))
        #expect(checker.manifestURL.absoluteString == "https://rssh-ea902a.gitlab.io/desktop/latest.json")
        #expect(checker.signatureURL.absoluteString == "https://rssh-ea902a.gitlab.io/desktop/latest.json.sig")
    }

    /// The pipeline signs with OpenSSL; prove its output verifies here: `openssl pkeyutl -sign -rawin` over the
    /// file, base64 of the raw signature; public key = last 32 bytes of the DER SubjectPublicKeyInfo.
    /// Linux only: macOS ships LibreSSL, whose pkeyutl has no -rawin, and BSD base64 has no -w0.
    @Test(.enabled(if: Platform.current == .linux && FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl")))
    func signatureMadeWithOpenSSLVerifies() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let key = "\(dir.path)/key.pem", manifest = "\(dir.path)/latest.json", sig = "\(dir.path)/latest.json.sig"
        try #"{"version":"1.0.0","assets":{}}"#.write(toFile: manifest, atomically: true, encoding: .utf8)
        #expect(try run("/usr/bin/openssl", ["genpkey", "-algorithm", "ed25519", "-out", key]).0 == 0)
        let (status, output) = try run("/bin/sh", ["-c",
            "openssl pkeyutl -sign -inkey \(key) -rawin -in \(manifest) | base64 -w0 > \(sig) && openssl pkey -in \(key) -pubout -outform DER | tail -c 32 | base64 -w0"])
        #expect(status == 0, "\(output)")
        let trust = UpdateTrust(base64Keys: [output.trimmingCharacters(in: .whitespacesAndNewlines)])
        #expect(trust.publicKeys.count == 1)
        try trust.verify(try Data(contentsOf: URL(fileURLWithPath: manifest)),
                         signatureFile: try Data(contentsOf: URL(fileURLWithPath: sig)))
    }
}
