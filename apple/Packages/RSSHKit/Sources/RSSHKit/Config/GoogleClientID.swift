import Foundation

/// The Google iOS OAuth client id from Info.plist (GIDClientID); a placeholder means sign-in is not set up yet.
public enum GoogleClientID {
    public static func isConfigured(_ value: String?) -> Bool {
        guard let value, value.hasSuffix(".apps.googleusercontent.com") else { return false }
        return !value.contains("REPLACE_ME") && !value.contains("$(") && value.count > ".apps.googleusercontent.com".count
    }
}
