import Foundation

/// Why a template does not parse; `description` names the place for the settings page.
public struct TabTitleTemplateError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    /// Character offset in the template.
    public let offset: Int

    public var description: String { "\(message) (at \(offset + 1))" }
}

/// A tab title template. Syntax (docs/research/tab-titles.md):
///
/// - `{host}`: a placeholder; `{args:30}` caps it at 30 characters with an ellipsis in the middle.
/// - `{custom|server|user@host}`: the first alternative whose placeholders all have a value; inside an
///   alternative, placeholder names are replaced and other characters stay (`user@host`); `"text"` is a literal
///   that always qualifies (`{custom|"Shell"}`).
/// - `{process? · {process} {args}}`: the body when `process` has a value; `{!process? {cwdShort}}` when it has
///   none. Bodies nest.
/// - `{{` and `}}` are literal braces.
///
/// The result has whitespace runs folded and no separator (`·`, `-`, `|`, `:`) hanging at either end, so
/// sections that drop out leave no trace.
public struct TabTitleTemplate: Equatable, Sendable {
    public struct Caps: Equatable, Sendable {
        public var args = 40
        public var path = 40
        public var other = 48
    }

    public static let defaultCaps = Caps()

    indirect enum Node: Equatable, Sendable {
        case text(String)
        case choice([Alternative])
        case condition(negated: Bool, TabTitlePlaceholder, [Node])
    }

    struct Alternative: Equatable, Sendable {
        enum Part: Equatable, Sendable {
            case literal(String)
            case placeholder(TabTitlePlaceholder, width: Int?)
        }
        var parts: [Part]
    }

    public let source: String
    let nodes: [Node]

    public init(_ source: String) throws(TabTitleTemplateError) {
        self.source = source
        var parser = Parser(Array(source))
        nodes = try parser.parseTemplate(closing: false)
    }

    public func render(_ facts: TabTitleFacts, caps: Caps = TabTitleTemplate.defaultCaps) -> String {
        TitleText.clean(Self.render(nodes, facts, caps))
    }

    /// Renders `source`, or `fallback` when `source` does not parse.
    public static func render(_ source: String, _ facts: TabTitleFacts, fallback: String) -> String {
        if let template = try? TabTitleTemplate(source) { return template.render(facts) }
        return (try? TabTitleTemplate(fallback))?.render(facts) ?? ""
    }

    // MARK: rendering

    private static func render(_ nodes: [Node], _ facts: TabTitleFacts, _ caps: Caps) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let text):
                out += text
            case .condition(let negated, let placeholder, let body):
                if facts.value(placeholder).isEmpty == negated { out += render(body, facts, caps) }
            case .choice(let alternatives):
                for alternative in alternatives {
                    if let text = render(alternative, facts, caps) {
                        out += text
                        break
                    }
                }
            }
        }
        return out
    }

    /// Nil when one of its placeholders has no value.
    private static func render(_ alternative: Alternative, _ facts: TabTitleFacts, _ caps: Caps) -> String? {
        var out = ""
        for part in alternative.parts {
            switch part {
            case .literal(let text):
                out += text
            case .placeholder(let placeholder, let width):
                let value = facts.value(placeholder)
                if value.isEmpty { return nil }
                out += TitleText.middleEllipsis(value, max: width ?? cap(placeholder, caps))
            }
        }
        return out
    }

    private static func cap(_ placeholder: TabTitlePlaceholder, _ caps: Caps) -> Int {
        switch placeholder {
        case .args, .title: caps.args
        case .cwd, .cwdShort: caps.path
        default: caps.other
        }
    }

    // MARK: parsing

    private struct Parser {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        func fail(_ message: String, at offset: Int? = nil) -> TabTitleTemplateError {
            TabTitleTemplateError(message: message, offset: offset ?? i)
        }

        mutating func parseTemplate(closing: Bool) throws(TabTitleTemplateError) -> [Node] {
            var nodes: [Node] = []
            var text = ""
            func flush() {
                if !text.isEmpty { nodes.append(.text(text)); text = "" }
            }
            while i < chars.count {
                let c = chars[i]
                if c == "{" {
                    if i + 1 < chars.count, chars[i + 1] == "{" {
                        text.append("{"); i += 2; continue
                    }
                    flush()
                    nodes.append(try parseSection())
                } else if c == "}" {
                    if closing { flush(); return nodes }
                    if i + 1 < chars.count, chars[i + 1] == "}" {
                        text.append("}"); i += 2; continue
                    }
                    throw fail("“}” without “{”")
                } else {
                    text.append(c); i += 1
                }
            }
            if closing { throw fail("missing “}”") }
            flush()
            return nodes
        }

        /// At `{`; consumes through the matching `}`.
        mutating func parseSection() throws(TabTitleTemplateError) -> Node {
            let open = i
            i += 1
            if let condition = try parseConditionHead() {
                let body = try parseTemplate(closing: true)
                i += 1 // the closing brace
                return .condition(negated: condition.negated, condition.placeholder, body)
            }
            var alternatives: [Alternative] = []
            while true {
                alternatives.append(try parseAlternative(sectionStart: open))
                guard i < chars.count else { throw fail("missing “}”", at: open) }
                if chars[i] == "|" { i += 1; continue }
                if chars[i] == "}" { i += 1; break }
                throw fail("“{” inside a placeholder")
            }
            return .choice(alternatives)
        }

        /// `name?` or `!name?` at the start of a section; leaves `i` after the `?`. Nil (and `i` unchanged) for
        /// anything else.
        mutating func parseConditionHead() throws(TabTitleTemplateError) -> (negated: Bool, placeholder: TabTitlePlaceholder)? {
            var j = i
            let negated = j < chars.count && chars[j] == "!"
            if negated { j += 1 }
            let nameStart = j
            while j < chars.count, chars[j].isLetter || chars[j].isNumber { j += 1 }
            guard j < chars.count, chars[j] == "?" else {
                if negated { throw fail("“!” needs “name?”", at: i) }
                return nil
            }
            let name = String(chars[nameStart..<j])
            guard !name.isEmpty else { throw fail("“?” needs a placeholder name before it", at: j) }
            guard let placeholder = TabTitlePlaceholder(rawValue: name) else {
                throw fail("unknown placeholder “\(name)”", at: nameStart)
            }
            i = j + 1
            return (negated, placeholder)
        }

        mutating func parseAlternative(sectionStart: Int) throws(TabTitleTemplateError) -> Alternative {
            var parts: [Alternative.Part] = []
            var literal = ""
            var hasPlaceholder = false
            func flush() {
                if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
            }
            let start = i
            while i < chars.count, chars[i] != "|", chars[i] != "}" {
                let c = chars[i]
                if c == "{" { throw fail("“{” inside a placeholder") }
                if c == "\"" {
                    i += 1
                    while i < chars.count, chars[i] != "\"" { literal.append(chars[i]); i += 1 }
                    guard i < chars.count else { throw fail("missing closing quote", at: start) }
                    i += 1
                    continue
                }
                if c.isLetter {
                    let nameStart = i
                    while i < chars.count, chars[i].isLetter || chars[i].isNumber { i += 1 }
                    let name = String(chars[nameStart..<i])
                    guard let placeholder = TabTitlePlaceholder(rawValue: name) else {
                        throw fail("unknown placeholder “\(name)”", at: nameStart)
                    }
                    var width: Int?
                    if i < chars.count, chars[i] == ":" {
                        i += 1
                        let digitsStart = i
                        while i < chars.count, chars[i].isNumber { i += 1 }
                        guard let n = Int(String(chars[digitsStart..<i])), n > 0 else {
                            throw fail("“:” needs a width above 0", at: digitsStart)
                        }
                        width = n
                    }
                    flush()
                    parts.append(.placeholder(placeholder, width: width))
                    hasPlaceholder = true
                    continue
                }
                literal.append(c)
                i += 1
            }
            flush()
            if parts.isEmpty { throw fail("empty placeholder", at: sectionStart) }
            if !hasPlaceholder, chars[start] != "\"" {
                throw fail("no placeholder name (quote literal text: \"text\")", at: start)
            }
            return Alternative(parts: parts)
        }
    }
}
