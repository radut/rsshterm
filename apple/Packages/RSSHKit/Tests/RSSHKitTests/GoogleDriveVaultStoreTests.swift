import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RSSHKit

/// Answers each request with the next scripted response and records what was sent.
actor FakeTransport: HTTPTransport {
    struct Reply {
        let status: Int
        let body: Data
        init(_ status: Int, _ body: String = "") {
            self.status = status
            self.body = Data(body.utf8)
        }
    }

    private var replies: [Reply]
    private(set) var sent: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (reply.body, response)
    }
}

@Suite struct GoogleDriveVaultStoreTests {
    static let listEmpty = #"{"files":[]}"#
    static let listOne = #"{"files":[{"id":"F1","version":"5","headRevisionId":"r5"}]}"#

    func store(_ transport: FakeTransport) -> GoogleDriveVaultStore {
        GoogleDriveVaultStore(transport: transport, accessToken: { "tok-123" })
    }

    @Test func loadWhenNoFileIsNil() async throws {
        let t = FakeTransport([.init(200, Self.listEmpty)])
        #expect(try await store(t).load() == nil)
        let req = try #require(await t.sent.first)
        let url = try #require(req.url?.absoluteString)
        #expect(url.hasPrefix("https://www.googleapis.com/drive/v3/files?"))
        #expect(url.contains("spaces=appDataFolder"))
        #expect(url.contains("rssh-vault.json"))
        #expect(req.httpMethod == "GET")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
    }

    @Test func loadDownloadsContentWithVersionAsRevision() async throws {
        let t = FakeTransport([.init(200, Self.listOne), .init(200, "ENVELOPE")])
        let loaded = try await store(t).load()
        #expect(loaded == StoredVault(data: Data("ENVELOPE".utf8), revision: "5"))
        let download = await t.sent[1]
        #expect(download.url?.absoluteString == "https://www.googleapis.com/drive/v3/files/F1?alt=media")
    }

    @Test func loadOfFileDeletedMeanwhileIsNil() async throws {
        let t = FakeTransport([.init(200, Self.listOne), .init(404, #"{"error":{"code":404,"message":"File not found"}}"#)])
        #expect(try await store(t).load() == nil)
    }

    @Test func saveCreatesTheFileWithAMultipartUpload() async throws {
        let t = FakeTransport([.init(200, Self.listEmpty), .init(200, #"{"id":"F1","version":"1"}"#)])
        let rev = try await store(t).save(Data("ENV".utf8), ifMatch: nil)
        #expect(rev == "1")
        let create = await t.sent[1]
        #expect(create.httpMethod == "POST")
        let url = try #require(create.url?.absoluteString)
        #expect(url.hasPrefix("https://www.googleapis.com/upload/drive/v3/files?"))
        #expect(url.contains("uploadType=multipart"))
        let type = try #require(create.value(forHTTPHeaderField: "Content-Type"))
        #expect(type.hasPrefix("multipart/related; boundary="))
        let body = String(decoding: try #require(create.httpBody), as: UTF8.self)
        #expect(body.contains(#""parents":["appDataFolder"]"#))
        #expect(body.contains(#""name":"rssh-vault.json""#))
        #expect(body.contains("ENV"))
    }

    @Test func saveUpdatesWhenRevisionMatches() async throws {
        let t = FakeTransport([.init(200, Self.listOne), .init(200, #"{"id":"F1","version":"6"}"#)])
        let rev = try await store(t).save(Data("NEW".utf8), ifMatch: "5")
        #expect(rev == "6")
        let update = await t.sent[1]
        #expect(update.httpMethod == "PATCH")
        #expect(update.url?.absoluteString.hasPrefix("https://www.googleapis.com/upload/drive/v3/files/F1?") == true)
        #expect(update.url?.absoluteString.contains("uploadType=media") == true)
        #expect(update.httpBody == Data("NEW".utf8))
    }

    @Test func saveWithStaleRevisionConflictsWithoutWriting() async throws {
        let t = FakeTransport([.init(200, Self.listOne)])
        await #expect(throws: VaultStoreError.conflict(currentRevision: "5")) {
            try await store(t).save(Data("NEW".utf8), ifMatch: "4")
        }
        #expect(await t.sent.count == 1)
    }

    @Test func saveWithoutRevisionOverExistingFileConflicts() async throws {
        let t = FakeTransport([.init(200, Self.listOne)])
        await #expect(throws: VaultStoreError.conflict(currentRevision: "5")) {
            try await store(t).save(Data("NEW".utf8), ifMatch: nil)
        }
    }

    @Test func unauthorizedIsReported() async throws {
        let t = FakeTransport([.init(401, #"{"error":{"code":401,"message":"Invalid Credentials"}}"#)])
        await #expect(throws: RemoteStoreError.unauthorized) { try await store(t).load() }
    }

    @Test func otherHTTPErrorsCarryTheServerMessage() async throws {
        let t = FakeTransport([.init(500, #"{"error":{"code":500,"message":"Backend Error"}}"#)])
        await #expect(throws: RemoteStoreError.http(status: 500, message: "Backend Error")) { try await store(t).load() }
    }

    @Test func tokenProviderFailureStopsBeforeAnyRequest() async throws {
        struct NotSignedIn: Error {}
        let t = FakeTransport([])
        let s = GoogleDriveVaultStore(transport: t, accessToken: { throw NotSignedIn() })
        await #expect(throws: NotSignedIn.self) { try await s.load() }
        #expect(await t.sent.isEmpty)
    }
}
