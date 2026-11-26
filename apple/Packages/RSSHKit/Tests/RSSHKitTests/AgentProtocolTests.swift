import Foundation
import Testing
@testable import RSSHKit

@Suite struct AgentFramerTests {
    @Test func splitsMessagesArrivingInAnySplit() throws {
        let stream = AgentFramer.frame(Data([11])) + AgentFramer.frame(Data([13, 1, 2, 3]))
        for cut in 0...stream.count {
            var framer = AgentFramer()
            var got = try framer.append(stream.prefix(cut))
            got += try framer.append(stream.dropFirst(cut))
            #expect(got == [Data([11]), Data([13, 1, 2, 3])])
        }
    }

    @Test func byteByByteDeliversEachMessageOnce() throws {
        var framer = AgentFramer()
        var got: [Data] = []
        for byte in AgentFramer.frame(Data([5])) + AgentFramer.frame(Data([6])) {
            got += try framer.append([byte])
        }
        #expect(got == [Data([5]), Data([6])])
    }

    @Test func refusesEmptyAndOversizedMessages() {
        var framer = AgentFramer()
        #expect(throws: AgentFramer.FramingError.emptyMessage) { try framer.append([0, 0, 0, 0]) }
        var big = AgentFramer()
        let length = AgentFramer.maximumMessageSize + 1
        let header = [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)]
        #expect(throws: AgentFramer.FramingError.tooLarge(length)) { try big.append(header) }
    }

    @Test func acceptsTheMaximumSize() throws {
        var framer = AgentFramer()
        let payload = Data(repeating: 7, count: AgentFramer.maximumMessageSize)
        #expect(try framer.append(AgentFramer.frame(payload)) == [payload])
    }

    @Test func framesWithABigEndianLength() {
        #expect(AgentFramer.frame(Data([12, 0])) == Data([0, 0, 0, 2, 12, 0]))
    }
}

@Suite struct AgentRequestTests {
    private func signPayload(blob: Data, data: Data, flags: UInt32, extra: Data = Data()) -> Data {
        var writer = SSHWireWriter()
        writer.raw(Data([AgentMessage.signRequest]))
        writer.string(blob)
        writer.string(data)
        writer.uint32(flags)
        writer.raw(extra)
        return writer.data
    }

    @Test func parsesRequestIdentities() {
        #expect(AgentRequest(payload: Data([11])) == .requestIdentities)
        #expect(AgentRequest(payload: Data([11, 0])) == .unsupported(11))
    }

    @Test func parsesSignRequests() {
        let payload = signPayload(blob: Data([1, 2]), data: Data([3]), flags: 4)
        #expect(AgentRequest(payload: payload) == .sign(keyBlob: Data([1, 2]), data: Data([3]), flags: 4))
    }

    @Test func truncatedOrTrailingSignRequestsAreRefused() {
        let payload = signPayload(blob: Data([1, 2]), data: Data([3]), flags: 4)
        for cut in 1..<payload.count {
            #expect(AgentRequest(payload: payload.prefix(cut)) == .unsupported(13))
        }
        #expect(AgentRequest(payload: signPayload(blob: Data(), data: Data(), flags: 0, extra: Data([9])))
            == .unsupported(13))
    }

    @Test func lyingLengthsDoNotTrap() {
        var payload = Data([13, 0xff, 0xff, 0xff, 0xff])
        payload.append(Data(repeating: 1, count: 16))
        #expect(AgentRequest(payload: payload) == .unsupported(13))
        #expect(AgentRequest(payload: Data()) == .unsupported(0))
    }

    @Test func everyOtherTypeIsUnsupported() {
        // add identity (17), remove (18), remove all (19), lock (22), unlock (23), extension (27), …
        for type in UInt8.min...UInt8.max where type != 11 && type != 13 {
            #expect(AgentRequest(payload: Data([type, 0, 0, 0, 0])) == .unsupported(type))
        }
    }

    @Test func fuzzedPayloadsNeverTrap() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let count = Int.random(in: 0...64, using: &rng)
            var bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if !bytes.isEmpty, Bool.random(using: &rng) { bytes[0] = 13 }
            _ = AgentRequest(payload: Data(bytes))
        }
    }
}

@Suite struct AgentResponseTests {
    @Test func failureIsOneByte() {
        #expect(AgentResponse.failure.payload == Data([5]))
    }

    @Test func identitiesAnswerLayout() {
        let payload = AgentResponse.identities([AgentIdentity(publicBlob: Data([1]), comment: "a")]).payload
        #expect(payload == Data([12, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 0x61]))
        #expect(AgentResponse.identities([]).payload == Data([12, 0, 0, 0, 0]))
    }

    @Test func signResponseLayout() {
        #expect(AgentResponse.signature(Data([9, 9])).payload == Data([14, 0, 0, 0, 2, 9, 9]))
    }
}

@Suite struct AgentSignRequestTests {
    @Test(arguments: ["publickey", "publickey-hostbound-v00@openssh.com"])
    func readsTheLoginUserOfAUserauthPayload(method: String) {
        var writer = SSHWireWriter()
        writer.string(Data(repeating: 1, count: 32))
        writer.raw(Data([50]))
        writer.string("deploy")
        writer.string("ssh-connection")
        writer.string(method)
        writer.raw(Data([1]))
        writer.string("ssh-ed25519")
        writer.string(Data([1, 2, 3]))
        #expect(AgentSignRequest.loginUser(in: writer.data) == "deploy")
    }

    @Test func otherMethodsHaveNoLoginUser() {
        var writer = SSHWireWriter()
        writer.string(Data(repeating: 1, count: 32))
        writer.raw(Data([50]))
        writer.string("deploy")
        writer.string("ssh-connection")
        writer.string("hostbased")
        #expect(AgentSignRequest.loginUser(in: writer.data) == nil)
    }

    @Test func otherDataHasNoLoginUser() {
        #expect(AgentSignRequest.loginUser(in: Data("hello".utf8)) == nil)
        #expect(AgentSignRequest.loginUser(in: Data()) == nil)
    }
}
