import Foundation

/// AWS access keys, long-lived or temporary. `description` never shows the secret or the token.
public struct AWSCredentials: Hashable, Sendable, CustomStringConvertible {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?
    /// When temporary credentials stop working; nil for long-lived keys.
    public var expiration: Date?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, expiration: Date? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }

    /// True when the credentials expire within `margin` of `now`.
    public func expires(within margin: TimeInterval, of now: Date) -> Bool {
        guard let expiration else { return false }
        return expiration.timeIntervalSince(now) <= margin
    }

    public var description: String {
        "AWSCredentials(accessKeyID: \(accessKeyID), expiration: \(expiration.map { "\($0)" } ?? "none"))"
    }
}

/// Where AWS credentials come from (access keys the user enters, fixed ones in tests).
public protocol AWSCredentialProvider: Sendable {
    func credentials() async throws -> AWSCredentials
    /// Forget cached credentials, e.g. after AWS called them expired.
    func invalidate() async
}
