import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RSSHKit

/// Vectors from AWS's published Signature Version 4 test suite (aws4_testsuite: credentials AKIDEXAMPLE, region
/// us-east-1, service "service", 2015-08-30T12:36:00Z).
@Suite struct SigV4Tests {
    static let creds = AWSCredentials(accessKeyID: "AKIDEXAMPLE",
                                      secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    static let date = Date(timeIntervalSince1970: 1_440_938_160)   // 20150830T123600Z
    static let signer = SigV4Signer(credentials: creds, region: "us-east-1", service: "service")
    static let prefix = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "

    /// A request as plain parts, so header values reach the signer exactly as the suite writes them.
    struct Parts {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    func request(_ method: String, _ path: String, headers: [String: String] = [:], body: String = "") -> Parts {
        Parts(method: method, url: URL(string: "https://example.amazonaws.com" + path)!, headers: headers, body: Data(body.utf8))
    }

    func signed(_ r: Parts, signer: SigV4Signer = SigV4Tests.signer) -> [String: String] {
        signer.signedHeaders(method: r.method, url: r.url, headers: r.headers, body: r.body, date: Self.date)
    }

    func authorization(_ r: Parts, signer: SigV4Signer = SigV4Tests.signer) -> String? {
        signed(r, signer: signer)["Authorization"]
    }

    @Test func getVanilla() {
        let headers = signed(request("GET", "/"))
        #expect(headers["X-Amz-Date"] == "20150830T123600Z")
        #expect(headers["Authorization"] == Self.prefix
            + "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func queryOrderKeyCase() {
        #expect(authorization(request("GET", "/?Param2=value2&Param1=value1")) == Self.prefix
            + "SignedHeaders=host;x-amz-date, Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500")
    }

    @Test func emptyQueryKey() {
        #expect(authorization(request("GET", "/?Param1=value1")) == Self.prefix
            + "SignedHeaders=host;x-amz-date, Signature=a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb")
    }

    @Test func queryUnreserved() {
        let u = "-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        #expect(authorization(request("GET", "/?\(u)=\(u)")) == Self.prefix
            + "SignedHeaders=host;x-amz-date, Signature=9c3e54bfcdf0b19771a7f523ee5669cdf59bc7cc0884027167c21bb143a40197")
    }

    @Test func utf8Path() {
        let path = "/" + "\u{1234}".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        #expect(authorization(request("GET", path)) == Self.prefix
            + "SignedHeaders=host;x-amz-date, Signature=8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85")
    }

    @Test func headerValueTrim() {
        let r = request("GET", "/", headers: ["My-Header1": " value1", "My-Header2": " \"a   b   c\""])
        #expect(authorization(r) == Self.prefix + "SignedHeaders=host;my-header1;my-header2;x-amz-date, "
            + "Signature=acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736")
    }

    @Test func headerValueMultiline() {
        let r = request("GET", "/", headers: ["My-Header1": "value1\n  value2\n     value3"])
        #expect(authorization(r) == Self.prefix + "SignedHeaders=host;my-header1;x-amz-date, "
            + "Signature=cfd34249e4b1c8d6b91ef74165d41a32e5fab3306300901bb65a51a73575eefd")
    }

    @Test func postHeaderValueCase() {
        #expect(authorization(request("POST", "/", headers: ["My-Header1": "VALUE1"])) == Self.prefix
            + "SignedHeaders=host;my-header1;x-amz-date, Signature=cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d")
    }

    @Test func postFormBody() {
        let r = request("POST", "/", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: "Param1=value1")
        #expect(authorization(r) == Self.prefix + "SignedHeaders=content-type;host;x-amz-date, "
            + "Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a")
    }

    @Test func sessionTokenIsSigned() {
        let token = "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8Y"
            + "UuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8Y"
            + "QcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2IC"
            + "CR/oLxBA=="
        let withToken = SigV4Signer(credentials: AWSCredentials(accessKeyID: Self.creds.accessKeyID,
                                                                secretAccessKey: Self.creds.secretAccessKey,
                                                                sessionToken: token),
                                    region: "us-east-1", service: "service")
        let headers = signed(request("POST", "/"), signer: withToken)
        #expect(headers["X-Amz-Security-Token"] == token)
        #expect(headers["Authorization"] == Self.prefix + "SignedHeaders=host;x-amz-date;x-amz-security-token, "
            + "Signature=85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead")
    }

    @Test func signsAURLRequestLikeItsParts() {
        var original = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        original.httpMethod = "POST"
        original.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        original.httpBody = Data("Param1=value1".utf8)
        let signed = Self.signer.sign(original, date: Self.date)
        #expect(signed.url == original.url)
        #expect(signed.httpBody == original.httpBody)
        #expect(signed.value(forHTTPHeaderField: "Host") == "example.amazonaws.com")
        #expect(signed.value(forHTTPHeaderField: "Authorization") == Self.prefix + "SignedHeaders=content-type;host;x-amz-date, "
            + "Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a")
        #expect(original.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func nonDefaultPortIsPartOfHost() {
        let r = Parts(method: "GET", url: URL(string: "http://localhost:4566/")!, headers: [:], body: Data())
        #expect(signed(r)["Host"] == "localhost:4566")
    }

    @Test func credentialsDescriptionHidesSecrets() {
        let c = AWSCredentials(accessKeyID: "AKID", secretAccessKey: "SECRET", sessionToken: "TOKEN")
        #expect(!String(describing: c).contains("SECRET"))
        #expect(!String(describing: c).contains("TOKEN"))
    }
}
