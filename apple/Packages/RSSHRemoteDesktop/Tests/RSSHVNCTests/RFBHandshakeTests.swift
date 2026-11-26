import Foundation
import Testing
@testable import RSSHVNC

@Suite struct RFBHandshakeTests {
    @Test(arguments: [("RFB 003.008\n", 3, 8), ("RFB 003.889\n", 3, 889), ("RFB 003.003\n", 3, 3)])
    func parsesVersions(text: String, major: Int, minor: Int) throws {
        let v = try RFBHandshake.parseVersion(Array(text.utf8))
        #expect(v.major == major && v.minor == minor)
    }

    @Test func refusesWhatIsNotRFB() {
        #expect(throws: RFBHandshakeError.notRFB("SSH-2.0-Open")) {
            try RFBHandshake.parseVersion(Array("SSH-2.0-OpenSSH_9.6\r\n".utf8))
        }
        #expect(throws: RFBHandshakeError.truncated) { try RFBHandshake.parseVersion(Array("RFB 003".utf8)) }
    }

    @Test func answersAppleWith38() {
        #expect(String(decoding: RFBHandshake.clientVersion(major: 3, minor: 889), as: UTF8.self) == "RFB 003.008\n")
        #expect(String(decoding: RFBHandshake.clientVersion(major: 3, minor: 7), as: UTF8.self) == "RFB 003.007\n")
        #expect(String(decoding: RFBHandshake.clientVersion(major: 3, minor: 3), as: UTF8.self) == "RFB 003.003\n")
    }

    @Test func parsesTheSecurityList() throws {
        #expect(RFBHandshake.parseSecurity([4, 30, 33, 36, 35], major: 3, minor: 889)?.types
            == [.appleDiffieHellman, .apple33, .apple36, .apple35])
        #expect(RFBHandshake.parseSecurity([2, 2], major: 3, minor: 8) == nil)   // one byte short
        #expect(RFBHandshake.parseSecurity([], major: 3, minor: 8) == nil)
    }

    @Test func parsesARefusalWithItsReason() throws {
        let reason = Array("Too many security failures".utf8)
        let bytes = [0, 0, 0, 0, UInt8(reason.count)] + reason
        let parsed = try #require(RFBHandshake.parseSecurity(bytes, major: 3, minor: 8))
        #expect(parsed.types.isEmpty)
        #expect(parsed.reason == "Too many security failures")
        #expect(RFBHandshake.parseSecurity(Array(bytes.dropLast()), major: 3, minor: 8) == nil)
    }

    @Test func parsesRFB33WhereTheServerChoosesTheType() throws {
        #expect(RFBHandshake.parseSecurity([0, 0, 0, 2], major: 3, minor: 3)?.types == [.vncPassword])
        let reason = Array("no".utf8)
        let refused = try #require(RFBHandshake.parseSecurity([0, 0, 0, 0, 0, 0, 0, 2] + reason, major: 3, minor: 3))
        #expect(refused.reason == "no")
    }

    @Test func aHugeReasonLengthIsCapped() throws {
        let filler = [UInt8](repeating: 0x41, count: 4096)
        let parsed = try #require(RFBHandshake.parseSecurity([0, 0xff, 0xff, 0xff, 0xff] + filler, major: 3, minor: 8))
        #expect(parsed.reason?.count == 4096)
    }

    // MARK: plan

    func hello(_ types: [RFBSecurityType], minor: Int = 889) -> RFBServerHello {
        RFBServerHello(major: 3, minor: minor, securityTypes: types, failureReason: nil)
    }

    @Test func aMacAccountEntryUsesARDWhenOffered() {
        #expect(VNCAuthPlan.plan(for: hello([.appleDiffieHellman, .apple33, .vncPassword]), preferAccount: true)
            == .inApp(.appleDiffieHellman))
        #expect(VNCAuthPlan.plan(for: hello([.appleDiffieHellman, .vncPassword]), preferAccount: false)
            == .inApp(.vncPassword))
    }

    @Test func onlyApplesNewerTypesMeansScreenSharingApp() {
        #expect(VNCAuthPlan.plan(for: hello([.apple33, .apple36, .apple35]), preferAccount: true)
            == .screenSharingAppOnly)
    }

    @Test func unknownTypesAndRefusals() {
        #expect(VNCAuthPlan.plan(for: hello([.veNCrypt], minor: 8), preferAccount: false) == .unsupported([.veNCrypt]))
        let refused = RFBServerHello(major: 3, minor: 8, securityTypes: [], failureReason: "busy")
        #expect(VNCAuthPlan.plan(for: refused, preferAccount: false) == .refused("busy"))
        #expect(hello([]).isApple)
        #expect(!hello([], minor: 8).isApple)
    }
}

@Suite struct X11KeysymTests {
    @Test func asciiAndLatin1AreTheirOwnCodes() {
        #expect(X11Keysym.keysyms(typing: "aZ ~") == [0x61, 0x5a, 0x20, 0x7e])
        #expect(X11Keysym.keysym(for: "é") == 0xe9)
    }

    @Test func otherUnicodeUsesUnicodeKeysyms() {
        #expect(X11Keysym.keysym(for: "ă") == 0x0100_0103)
        #expect(X11Keysym.keysym(for: "€") == 0x0100_20ac)
    }

    @Test func controlCharacters() {
        #expect(X11Keysym.keysyms(typing: "a\r\nb\nc\td") == [0x61, X11Keysym.returnKey, 0x62, X11Keysym.returnKey,
                                                              0x63, X11Keysym.tab, 0x64])
        #expect(X11Keysym.keysym(for: "\u{07}") == nil)
        #expect(X11Keysym.keysym(for: "\u{1b}") == X11Keysym.escape)
    }

    @Test func functionKeys() {
        #expect(X11Keysym.function(1) == 0xffbe)
        #expect(X11Keysym.function(12) == 0xffc9)
        #expect(X11Keysym.function(0) == nil)
        #expect(X11Keysym.function(36) == nil)
    }
}
