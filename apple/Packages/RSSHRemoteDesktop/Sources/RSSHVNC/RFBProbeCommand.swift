import Foundation

/// `rssh-rfb-probe`: what a VNC server or a Mac offers, for the research notes and support. Connects, reads the
/// version and security types, hangs up before authenticating: no user, no password, nothing secret is sent or
/// printed. Point it at the local end of an SSH forward (`ssh -L 5901:localhost:5900 mac`) rather than at an open
/// port 5900.
public enum RFBProbeCommand {
    public static let usage = """
        usage: rssh-rfb-probe <host> [port] [--json]
          Prints the RFB version and security types the server offers and whether rSshTerm can log in.
          Reach a Mac through SSH first:  ssh -N -L 5901:localhost:5900 you@mac.example.net
                                          rssh-rfb-probe 127.0.0.1 5901
        """

    public struct UsageError: Error, CustomStringConvertible {
        public var description: String
    }

    public struct Options: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var json: Bool

        public static func parse(_ arguments: [String]) throws -> Options {
            let json = arguments.contains("--json")
            let rest = arguments.filter { $0 != "--json" }
            guard (1...2).contains(rest.count), !rest[0].hasPrefix("-") else { throw UsageError(description: usage) }
            var port = 5900
            if rest.count == 2 {
                guard let p = Int(rest[1]), (1...65535).contains(p) else {
                    throw UsageError(description: "rssh-rfb-probe: \(rest[1]) is not a port from 1 to 65535")
                }
                port = p
            }
            return Options(host: rest[0], port: port, json: json)
        }
    }

    /// Runs the probe; returns the exit status and what to print.
    public static func run(_ arguments: [String]) async -> (Int32, String) {
        let options: Options
        do { options = try Options.parse(arguments) } catch { return (2, String(describing: error)) }
        do {
            let hello = try await RFBProbe.hello(host: options.host, port: options.port)
            return (0, options.json ? json(hello) : report(hello, host: options.host, port: options.port))
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return (1, "rssh-rfb-probe: \(options.host):\(options.port): \(reason)")
        }
    }

    public static func report(_ hello: RFBServerHello, host: String, port: Int) -> String {
        var lines = ["\(host):\(port)  RFB \(hello.major).\(String(format: "%03d", hello.minor))"
                     + (hello.isApple ? " (macOS Screen Sharing)" : "")]
        if let reason = hello.failureReason { lines.append("refused: \(printable(reason))") }
        for type in hello.securityTypes {
            let inApp = RFBSecurityType.supported.contains(type) ? "yes" : "no"
            lines.append("  \(type.rawValue) \(type)  in-app: \(inApp)")
        }
        lines.append("Mac account entry: " + describe(VNCAuthPlan.plan(for: hello, preferAccount: true)))
        lines.append("VNC password entry: " + describe(VNCAuthPlan.plan(for: hello, preferAccount: false)))
        return lines.joined(separator: "\n")
    }

    /// One object: version, type numbers, the two plans, the refusal reason (or null). Nothing else.
    public static func json(_ hello: RFBServerHello) -> String {
        let object: [String: Any] = [
            "version": "\(hello.major).\(String(format: "%03d", hello.minor))",
            "securityTypes": hello.securityTypes.map { Int($0.rawValue) },
            "macAccountPlan": slug(VNCAuthPlan.plan(for: hello, preferAccount: true)),
            "vncPasswordPlan": slug(VNCAuthPlan.plan(for: hello, preferAccount: false)),
            "failureReason": hello.failureReason ?? NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func describe(_ plan: VNCAuthPlan) -> String {
        switch plan {
        case .inApp(let type): "in the app with \(type)"
        case .screenSharingAppOnly: "only Apple's Screen Sharing app (or set a VNC password on the Mac)"
        case .unsupported(let types): "no login this app knows (\(types.map(\.description).joined(separator: ", ")))"
        case .refused(let reason): "refused: \(printable(reason))"
        }
    }

    /// Server text made safe for a terminal: control characters (ESC, C0, C1, DEL) shown as \u{..}, at most 200
    /// characters, so a hostile server cannot drive the terminal the probe prints to.
    static func printable(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars.prefix(200) {
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                out += "\\u{\(String(scalar.value, radix: 16))}"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return text.unicodeScalars.count > 200 ? out + "…" : out
    }

    static func slug(_ plan: VNCAuthPlan) -> String {
        switch plan {
        case .inApp(let type): "in-app-\(type.rawValue)"
        case .screenSharingAppOnly: "screen-sharing-app-only"
        case .unsupported: "unsupported"
        case .refused: "refused"
        }
    }
}
