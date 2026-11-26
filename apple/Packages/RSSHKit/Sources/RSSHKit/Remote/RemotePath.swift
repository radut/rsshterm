import Foundation

/// Paths on the server: joining, naming an upload, and quoting for a POSIX shell.
public enum RemotePath {
    /// `path` ready to paste into a shell command. Plain paths stay as they are; anything else is single-quoted,
    /// with each `'` written as `'\''`. A leading `~/` is left outside the quotes so the shell still expands it.
    public static func shellQuoted(_ path: String) -> String {
        if path.hasPrefix("~/") { return "~/" + shellQuoted(String(path.dropFirst(2))) }
        if !path.isEmpty, path.unicodeScalars.allSatisfy(isPlain) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `directory` + `/` + `name`, without doubling the slash.
    public static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// A file name the server will accept as one path component: slashes and control characters become `_`,
    /// surrounding spaces go, and an empty, `.` or `..` name becomes `fallback`.
    public static func safeFileName(_ name: String, fallback: String = "upload") -> String {
        let mapped = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            scalar == "/" || isControl(scalar) || ComposeKey.tokenCharacters.contains(Character(scalar)) ? "_" : scalar
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return mapped.isEmpty || mapped == "." || mapped == ".." ? fallback : mapped
    }

    /// The directory from an OSC 7 report (`file://host/path`, percent-encoded or not), or a bare absolute path.
    /// nil for anything else, and for a path that is not `isUsableDirectory` (the report comes from the remote).
    public static func directory(fromOSC7 report: String?) -> String? {
        guard let report = report?.trimmingCharacters(in: .whitespacesAndNewlines), !report.isEmpty else { return nil }
        let path: String
        if report.hasPrefix("/") {
            path = report
        } else {
            guard report.lowercased().hasPrefix("file://") else { return nil }
            let afterScheme = report.dropFirst("file://".count)
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            let raw = String(afterScheme[slash...])
            path = raw.removingPercentEncoding ?? raw
        }
        return isUsableDirectory(path) ? path : nil
    }

    /// An absolute path with no control characters and no compose key tokens: safe to show, edit and insert.
    public static func isUsableDirectory(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains(where: isControl)
            && !path.contains(where: ComposeKey.tokenCharacters.contains)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "/", ".", "_", "-", "+", ",", ":", "@", "%", "=": true
        default: false
        }
    }
}
