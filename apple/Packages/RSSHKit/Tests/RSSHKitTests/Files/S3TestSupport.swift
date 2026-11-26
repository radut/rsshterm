import Foundation
@testable import RSSHKit

/// Fixed credentials that count how often they were invalidated.
actor FixedCredentials: AWSCredentialProvider {
    private(set) var invalidations = 0
    private let error: KeyWrapperError?

    init(failing error: KeyWrapperError? = nil) { self.error = error }

    func credentials() async throws -> AWSCredentials {
        if let error { throw error }
        return AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: "tok")
    }

    func invalidate() async { invalidations += 1 }
}
