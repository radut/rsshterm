import Foundation

/// One `-----BEGIN <label>-----` … `-----END <label>-----` block (RFC 7468), read tolerantly: CR/LF, spaces, a
/// missing final newline, lines re-wrapped or joined by the clipboard. The legacy encryption headers (RFC 1421) are
/// found even when their line breaks were lost.
struct PEMBlock {
    let label: String
    /// `DEK-Info` cipher name and IV, when the block has `Proc-Type: 4,ENCRYPTED`.
    let dekInfo: (cipher: String, iv: [UInt8])?
    let body: [UInt8]
}

enum PEMArmor {
    private static let dashes = "-----"

    /// The label of the first BEGIN line in `text`, if any.
    static func firstLabel(in text: String) -> String? {
        guard let begin = text.range(of: dashes + "BEGIN ") else { return nil }
        guard let close = text.range(of: dashes, range: begin.upperBound..<text.endIndex) else { return nil }
        let label = text[begin.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    /// The first block in `text`; nil when it has no BEGIN line, `.failure` when the block is cut off or not base64.
    static func block(in text: String) -> Result<PEMBlock, PEMFailure>? {
        guard let label = firstLabel(in: text), let begin = text.range(of: "\(dashes)BEGIN \(label)\(dashes)") else {
            return nil
        }
        guard let end = text.range(of: "\(dashes)END \(label)\(dashes)", range: begin.upperBound..<text.endIndex) else {
            return .failure(.truncated(label))
        }
        var inside = String(text[begin.upperBound..<end.lowerBound])
        let dekInfo = takeLegacyHeaders(&inside)
        guard let body = base64(inside), !body.isEmpty else { return .failure(.notBase64(label)) }
        return .success(PEMBlock(label: label, dekInfo: dekInfo, body: body))
    }

    enum PEMFailure: Error, Equatable {
        case truncated(String), notBase64(String)
    }

    /// Decodes base64 that may carry whitespace, line breaks, or stray characters a clipboard added.
    static func base64(_ text: some StringProtocol) -> [UInt8]? {
        var cleaned = String(text.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") })
        guard cleaned.count % 4 != 1 else { return nil }
        cleaned += String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        return Data(base64Encoded: cleaned).map { [UInt8]($0) }
    }

    /// Removes `Proc-Type` and `DEK-Info` from the block text and returns the cipher and IV. The IV is read by the
    /// cipher's own length, so it still parses when the clipboard joined it to the first base64 line.
    private static func takeLegacyHeaders(_ text: inout String) -> (cipher: String, iv: [UInt8])? {
        guard let proc = text.range(of: "Proc-Type:") else { return nil }
        let afterProc = text[proc.upperBound...].drop { $0 == " " || $0 == "\t" }
        let procValue = afterProc.prefix { $0 == "," || $0.isNumber || $0.isLetter }
        guard let dek = text.range(of: "DEK-Info:") else {
            text.removeSubrange(proc.lowerBound..<procValue.endIndex)
            return procValue.contains("ENCRYPTED") ? ("", []) : nil
        }
        let rest = text[dek.upperBound...].drop { $0.isWhitespace }
        let cipher = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" })
        let afterComma = rest.dropFirst(cipher.count).drop { $0.isWhitespace || $0 == "," }
        let hexLength = Self.ivLength(cipher).map { $0 * 2 } ?? afterComma.prefix { $0.isHexDigit }.count
        let hex = afterComma.prefix(hexLength)
        let iv = hexBytes(hex) ?? []
        text = String(text[..<proc.lowerBound]) + String(afterComma.dropFirst(hex.count))
        return (cipher.uppercased(), iv)
    }

    /// The IV length of the legacy PEM ciphers OpenSSL writes.
    static func ivLength(_ cipher: String) -> Int? {
        switch cipher.uppercased() {
        case "AES-128-CBC", "AES-192-CBC", "AES-256-CBC": 16
        case "DES-EDE3-CBC", "DES-CBC": 8
        default: nil
        }
    }

    static func hexBytes(_ hex: some StringProtocol) -> [UInt8]? {
        let digits = Array(hex)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
