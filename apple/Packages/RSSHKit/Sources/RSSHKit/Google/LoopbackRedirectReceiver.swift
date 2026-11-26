#if os(Linux) || os(macOS)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Listens on `127.0.0.1:<free port>` for the one browser request Google's redirect makes, answers it with a short
/// page and hands its URL to the sign-in. Bound to the loopback address only, so nothing else on the network can reach
/// it; any request without `code`/`error` (a favicon, a probe) gets a 404 and the wait goes on.
public final class LoopbackRedirectReceiver: RedirectReceiver, @unchecked Sendable {
    public let port: UInt16
    public var redirectURI: String { "http://127.0.0.1:\(port)" }

    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var waiting = false

    public init() throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw GoogleOAuthError.loopback("No socket: \(Self.lastError())") }
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, sa, &length) == 0
            }
        }
        guard ok else {
            let message = Self.lastError()
            closeSocket(fd)
            throw GoogleOAuthError.loopback(message)
        }
        self.fd = fd
        self.port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { close() }

    public func waitForRedirect(timeout: TimeInterval) async throws -> URL {
        try lock.withLock {
            guard !closed, !waiting else { throw GoogleOAuthError.loopback("The listener is closed or busy.") }
            waiting = true
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread { [self] in
                    let result = Result { try self.acceptLoop(until: Date().addingTimeInterval(timeout)) }
                    let shouldClose = lock.withLock { waiting = false; return closed }
                    if shouldClose { closeSocket(fd) }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            close()
        }
    }

    /// Stops listening; a wait in progress ends within a poll interval with `timedOut`.
    public func close() {
        let closeNow: Bool = lock.withLock {
            guard !closed else { return false }
            closed = true
            return !waiting
        }
        if closeNow { closeSocket(fd) }
    }

    private func acceptLoop(until deadline: Date) throws -> URL {
        while true {
            if lock.withLock({ closed }) { throw GoogleOAuthError.timedOut }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw GoogleOAuthError.timedOut }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 0.2) * 1000))
            guard ready > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            defer { closeSocket(client) }
            guard let target = Self.readTarget(client) else { continue }
            let url = URL(string: redirectURI + target)
            let query = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            guard let url, query.contains(where: { $0.name == "code" || $0.name == "error" }) else {
                Self.respond(client, status: "404 Not Found", body: "Not found.")
                continue
            }
            Self.respond(client, status: "200 OK", body: """
                <!doctype html><meta charset="utf-8"><title>rSshTerm</title>\
                <p style="font-family:sans-serif">rSshTerm has Google's answer. You can close this tab.</p>
                """)
            return url
        }
    }

    /// The request target of `GET <target> HTTP/1.x`, read with a 5 s limit so a silent client cannot hold the wait.
    private static func readTarget(_ client: Int32) -> String? {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 16_384, request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(client, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            request.append(contentsOf: buffer[0..<n])
        }
        let firstLine = String(decoding: request, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    private static func respond(_ client: Int32, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        let response = Data(head.utf8) + payload
        #if canImport(Glibc)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(client, raw.baseAddress! + offset, raw.count - offset, flags)
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    private static func lastError() -> String { String(cString: strerror(errno)) }
}

/// `close(2)`, named apart from `LoopbackRedirectReceiver.close()`.
private func closeSocket(_ fd: Int32) {
    _ = close(fd)
}
#endif
