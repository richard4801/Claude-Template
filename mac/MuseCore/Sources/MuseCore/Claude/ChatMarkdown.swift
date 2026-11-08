import Foundation

/// Claude's replies as blocks and styled runs, for the chat on the Mac (and the same rules as the Android chat): bold,
/// italic, strikethrough, inline code, code blocks, headings, lists (nested, ordered, tasks), blockquotes, links, tables and
/// rules. The markup itself is never shown: no `**`, backticks or `#` reach the screen, including mid-stream, when a span or
/// a fence hasn't closed yet (`streaming: true` styles it to the end instead, and drops a marker that has only just begun).
/// Lone markers that aren't markup ("2 * 3", "#Dolly in" mid-line, snake_case) stay as they are.
public enum ChatMarkdown {
    public static func parse(_ text: String, streaming: Bool = false) -> [ChatBlock] {
        let src = decodeBreaks(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var lines = src.components(separatedBy: "\n")
        if streaming { dropPendingTable(&lines) }
        return Parser(lines: lines, streaming: streaming).blocks()
    }

    /// Inline markup only (a table cell, a tool summary).
    public static func inline(_ text: String, streaming: Bool = false) -> [ChatRun] {
        InlineParser(text, streaming: streaming).runs()
    }

    /// The words without any markup, for VoiceOver, Copy as plain text and the tests.
    public static func plainText(_ blocks: [ChatBlock]) -> String {
        blocks.map(\.plainText).joined(separator: "\n\n")
    }

    private static func decodeBreaks(_ s: String) -> String {
        guard s.contains("<br") else { return s }
        return s.replacingOccurrences(of: "<br />", with: "\n").replacingOccurrences(of: "<br/>", with: "\n").replacingOccurrences(of: "<br>", with: "\n")
    }

    /// Mid-stream, "| Shot | Len |" arrives before its |---| row: hold the rows back until the table is a table, instead of
    /// showing pipes for a moment.
    private static func dropPendingTable(_ lines: inout [String]) {
        // Not inside a code fence that is still open.
        var open = false
        for l in lines where Parser.fence(l.trimmingCharacters(in: .whitespaces)) != nil { open.toggle() }
        guard !open else { return }
        var start = lines.count
        while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") { start -= 1 }
        let block = lines.count - start
        guard block > 0 else { return }
        let established = block >= 2 && Parser.isDelimiterRow(lines[start + 1].trimmingCharacters(in: .whitespaces))
            && (block > 2 || lines[start + 1].trimmingCharacters(in: .whitespaces).hasSuffix("|"))
        if !established { lines.removeSubrange(start...) }
    }
}

/// A run of text with one set of styles.
public struct ChatRun: Hashable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var strike = false
    public var code = false
    public var link: String?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, code: Bool = false, link: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.strike = strike
        self.code = code
        self.link = link
    }

    func sameStyle(_ o: ChatRun) -> Bool { bold == o.bold && italic == o.italic && strike == o.strike && code == o.code && link == o.link }
}

public enum ChatAlign: Hashable, Sendable { case leading, center, trailing }

public indirect enum ChatBlock: Hashable, Sendable {
    case paragraph([ChatRun])
    case heading(level: Int, [ChatRun])
    /// `number`: an ordered item's number; `checked`: a task item's box (nil for a plain item).
    case listItem(ordered: Bool, number: Int, depth: Int, checked: Bool?, [ChatRun])
    case quote([ChatBlock])
    /// `closed`: false while the fence is still streaming.
    case code(language: String?, text: String, closed: Bool)
    case table(header: [[ChatRun]], rows: [[[ChatRun]]], align: [ChatAlign])
    case rule

    public var plainText: String {
        switch self {
        case .paragraph(let r), .heading(_, let r): return ChatBlock.plain(r)
        case .listItem(let ordered, let n, let depth, let checked, let r):
            let mark = checked.map { $0 ? "[x] " : "[ ] " } ?? ""
            return String(repeating: "  ", count: depth) + (ordered ? "\(n). " : "• ") + mark + ChatBlock.plain(r)
        case .quote(let b): return b.map(\.plainText).joined(separator: "\n")
        case .code(_, let t, _): return t
        case .table(let h, let rows, _):
            return ([h] + rows).map { $0.map { ChatBlock.plain($0) }.joined(separator: "\t") }.joined(separator: "\n")
        case .rule: return ""
        }
    }

    static func plain(_ runs: [ChatRun]) -> String { runs.map(\.text).joined() }
}

// MARK: Blocks

private struct Parser {
    let lines: [String]
    let streaming: Bool

    func blocks() -> [ChatBlock] {
        var out: [ChatBlock] = []
        var para: [String] = []
        var i = 0
        let n = lines.count

        func isLastLine(_ idx: Int) -> Bool { idx >= n - 1 }
        func flush(endsText: Bool) {
            guard !para.isEmpty else { return }
            let text = para.joined(separator: "\n")
            para = []
            let runs = InlineParser(text, streaming: streaming && endsText).runs()
            if !runs.isEmpty { out.append(.paragraph(runs)) }
        }

        while i < n {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lead = Parser.indent(line)

            // Fenced code.
            if lead < 4, let fence = Parser.fence(trimmed) {
                flush(endsText: false)
                var body: [String] = []
                var j = i + 1
                var closed = false
                while j < n {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(String(repeating: String(fence.char), count: fence.count)), t.allSatisfy({ $0 == fence.char }) {
                        closed = true
                        break
                    }
                    body.append(Parser.dedent(lines[j], by: min(lead, Parser.indent(lines[j]))))
                    j += 1
                }
                // A closing fence still being typed ("``") isn't code.
                if streaming, !closed, let last = body.last, !last.isEmpty, last.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.char }) {
                    body.removeLast()
                }
                out.append(.code(language: fence.lang, text: body.joined(separator: "\n"), closed: closed || !streaming))
                i = closed ? j + 1 : n
                continue
            }

            if trimmed.isEmpty {
                flush(endsText: false)
                i += 1
                continue
            }

            // Setext heading underline ("Title\n===").
            if !para.isEmpty, lead < 4, trimmed.count >= 2, trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                let text = para.joined(separator: "\n")
                para = []
                out.append(.heading(level: trimmed.first == "=" ? 1 : 2, InlineParser(text, streaming: false).runs()))
                i += 1
                continue
            }

            if lead < 4, let h = Parser.heading(trimmed) {
                flush(endsText: false)
                let runs = InlineParser(h.text, streaming: streaming && isLastLine(i)).runs()
                if !runs.isEmpty { out.append(.heading(level: h.level, runs)) }   // "#" alone mid-stream: nothing yet
                i += 1
                continue
            }

            if lead < 4, Parser.isRule(trimmed) {
                flush(endsText: false)
                out.append(.rule)
                i += 1
                continue
            }

            if lead < 4, trimmed.hasPrefix(">") {
                flush(endsText: false)
                var inner: [String] = []
                var j = i
                while j < n {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = Substring(t.dropFirst())
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    j += 1
                }
                let blocks = Parser(lines: inner, streaming: streaming && j >= n).blocks()
                if !blocks.isEmpty { out.append(.quote(blocks)) }
                i = j
                continue
            }

            if let item = Parser.listItem(line) {
                flush(endsText: false)
                var text = item.text
                var j = i + 1
                // Lazy continuation: indented lines that aren't a new item or another block.
                while j < n {
                    let l = lines[j]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || Parser.listItem(l) != nil || Parser.fence(t) != nil || Parser.heading(t) != nil || Parser.isRule(t) || t.hasPrefix(">") { break }
                    if Parser.indent(l) < item.contentIndent && Parser.indent(l) == 0 { break }
                    text += "\n" + t
                    j += 1
                }
                var checked: Bool?
                if text.hasPrefix("[ ] ") || text == "[ ]" { checked = false; text = String(text.dropFirst(min(4, text.count))) }
                else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") || text == "[x]" || text == "[X]" { checked = true; text = String(text.dropFirst(min(4, text.count))) }
                let runs = InlineParser(text, streaming: streaming && j >= n).runs()
                out.append(.listItem(ordered: item.ordered, number: item.number, depth: item.depth, checked: checked, runs))
                i = j
                continue
            }

            // Table: a row with pipes over a delimiter row.
            if trimmed.contains("|"), i + 1 < n, Parser.isDelimiterRow(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let header = Parser.cells(trimmed)
                let delim = Parser.cells(lines[i + 1].trimmingCharacters(in: .whitespaces))
                if header.count >= 1, delim.count >= 1 {
                    flush(endsText: false)
                    let cols = header.count
                    let align: [ChatAlign] = (0..<cols).map { c in
                        guard c < delim.count else { return .leading }
                        let d = delim[c]
                        if d.hasPrefix(":") && d.hasSuffix(":") { return .center }
                        if d.hasSuffix(":") { return .trailing }
                        return .leading
                    }
                    var rows: [[[ChatRun]]] = []
                    var j = i + 2
                    while j < n {
                        let t = lines[j].trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty, t.contains("|") else { break }
                        if streaming, j == n - 1, !t.hasSuffix("|"), t.hasPrefix("|") { j += 1; break }   // a row still arriving
                        var cs = Parser.cells(t)
                        if cs.count < cols { cs += Array(repeating: "", count: cols - cs.count) }
                        rows.append(cs.prefix(cols).map { InlineParser($0, streaming: false).runs() })
                        j += 1
                    }
                    out.append(.table(header: header.map { InlineParser($0, streaming: false).runs() }, rows: rows, align: align))
                    i = j
                    continue
                }
            }

            para.append(trimmed)
            i += 1
        }
        flush(endsText: true)
        return out
    }

    // MARK: Line tests

    static func indent(_ line: String) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break }
        }
        return n
    }

    static func dedent(_ line: String, by k: Int) -> String {
        var s = Substring(line)
        var left = k
        while left > 0, let c = s.first, c == " " { s = s.dropFirst(); left -= 1 }
        return String(s)
    }

    static func fence(_ t: String) -> (char: Character, count: Int, lang: String?)? {
        guard let c = t.first, c == "`" || c == "~" else { return nil }
        let count = t.prefix { $0 == c }.count
        guard count >= 3 else { return nil }
        let info = t.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        let lang = info.split(separator: " ").first.map(String.init)
        return (c, count, lang?.isEmpty == false ? lang : nil)
    }

    static func heading(_ t: String) -> (level: Int, text: String)? {
        guard t.hasPrefix("#") else { return nil }
        let level = t.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes ("## Title ##").
        if let r = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(r) } else if text.allSatisfy({ $0 == "#" }) { text = "" }
        return (level, text)
    }

    static func isRule(_ t: String) -> Bool {
        let s = t.filter { $0 != " " }
        guard s.count >= 3, let c = s.first, c == "-" || c == "*" || c == "_" else { return false }
        return s.allSatisfy { $0 == c }
    }

    struct Item {
        var ordered: Bool
        var number: Int
        var depth: Int
        var text: String
        var contentIndent: Int
    }

    static func listItem(_ line: String) -> Item? {
        let lead = indent(line)
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let c = t.first else { return nil }
        let depth = min(4, lead / 2)
        if c == "-" || c == "*" || c == "+" {
            let rest = t.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            if isRule(t) { return nil }
            return Item(ordered: false, number: 0, depth: depth, text: rest.trimmingCharacters(in: .whitespaces), contentIndent: lead + 2)
        }
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = t.dropFirst(digits.count)
        guard let p = after.first, p == "." || p == ")" else { return nil }
        let rest = after.dropFirst()
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return Item(ordered: true, number: Int(digits) ?? 1, depth: depth, text: rest.trimmingCharacters(in: .whitespaces),
                    contentIndent: lead + digits.count + 2)
    }

    static func isDelimiterRow(_ t: String) -> Bool {
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        let cs = cells(t)
        guard !cs.isEmpty else { return false }
        return cs.allSatisfy { c in
            let s = c.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return false }
            let core = s.drop { $0 == ":" }
            let body = core.reversed().drop { $0 == ":" }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        } && t.contains("|")
    }

    static func cells(_ t: String) -> [String] {
        var s = Substring(t)
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s = s.dropLast() }
        var out: [String] = []
        var cur = ""
        var escaped = false
        var inCode = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; cur.append(ch); continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }
}

// MARK: Inline

private struct InlineParser {
    let chars: [Character]
    let streaming: Bool

    init(_ text: String, streaming: Bool) {
        chars = Array(text)
        self.streaming = streaming
    }

    /// One token of a line: text, code, a link (its own runs), or a run of `*`, `_` or `~` that may open or close.
    private enum Tok {
        case text(String)
        case code(String)
        case link([ChatRun], String)
        case delim(char: Character, count: Int, canOpen: Bool, canClose: Bool, atEnd: Bool)
    }

    private struct Styled {
        var tok: Tok
        var bold = 0, italic = 0, strike = 0
        var remaining = 0
    }

    func runs() -> [ChatRun] {
        var toks = tokens().map { t -> Styled in
            var s = Styled(tok: t)
            if case .delim(_, let c, _, _, _) = t { s.remaining = c }
            return s
        }
        resolveEmphasis(&toks)

        var out: [ChatRun] = []
        func add(_ r: ChatRun) {
            guard !r.text.isEmpty else { return }
            if let last = out.last, last.sameStyle(r) { out[out.count - 1].text += r.text } else { out.append(r) }
        }
        for s in toks {
            let b = s.bold > 0, it = s.italic > 0, st = s.strike > 0
            switch s.tok {
            case .text(let t): add(ChatRun(t, bold: b, italic: it, strike: st))
            case .code(let t): add(ChatRun(t, bold: b, italic: it, strike: st, code: true))
            case .link(let inner, let url):
                for r in inner { add(ChatRun(r.text, bold: b || r.bold, italic: it || r.italic, strike: st || r.strike, code: r.code, link: url)) }
            case .delim(let c, _, let canOpen, let canClose, let atEnd):
                guard s.remaining > 0 else { continue }
                // Leftover markers: shown only when they can't be markup ("2 * 3", "a ~ b"); a single ~ is text.
                let markup = canOpen || canClose || atEnd
                if !markup || (c == "~" && s.remaining == 1) {
                    add(ChatRun(String(repeating: String(c), count: s.remaining), bold: b, italic: it, strike: st))
                }
            }
        }
        // Trim a trailing newline the source might carry.
        if let last = out.last, last.text.hasSuffix("\n") {
            out[out.count - 1].text = String(last.text.dropLast())
            if out[out.count - 1].text.isEmpty { out.removeLast() }
        }
        return out
    }

    // MARK: Emphasis (CommonMark's delimiter rules, simplified)

    private func resolveEmphasis(_ toks: inout [Styled]) {
        var openers: [Int] = []
        var i = 0
        while i < toks.count {
            guard case .delim(let c, _, let canOpen, let canClose, _) = toks[i].tok else { i += 1; continue }
            if canClose {
                var k = openers.count - 1
                while k >= 0, toks[i].remaining > 0 {
                    let o = openers[k]
                    guard case .delim(let oc, _, _, _, _) = toks[o].tok, oc == c, toks[o].remaining > 0 else { k -= 1; continue }
                    if c == "~" && (toks[o].remaining < 2 || toks[i].remaining < 2) { k -= 1; continue }
                    // "**bold*" mid-stream: the closer is still being typed; keep it bold.
                    if case .delim(_, _, _, _, true) = toks[i].tok, toks[i].remaining < toks[o].remaining { break }
                    let use = c == "~" ? 2 : min(2, min(toks[o].remaining, toks[i].remaining))
                    for j in (o + 1)..<i {
                        if c == "~" { toks[j].strike += 1 } else if use == 2 { toks[j].bold += 1 } else { toks[j].italic += 1 }
                    }
                    toks[o].remaining -= use
                    toks[i].remaining -= use
                    // Openers between the pair can no longer close anything.
                    openers.removeSubrange((k + 1)...)
                    if toks[o].remaining == 0 { openers.remove(at: k) }
                    k = openers.count - 1
                }
            }
            if canOpen, toks[i].remaining > 0 { openers.append(i) }
            i += 1
        }
        // Streaming: an opener that hasn't closed yet styles to the end (its marker hidden).
        guard streaming else { return }
        for o in openers {
            guard case .delim(let c, _, _, _, _) = toks[o].tok, toks[o].remaining > 0 else { continue }
            let r = toks[o].remaining
            if c == "~" && r < 2 { continue }
            for j in (o + 1)..<toks.count {
                if c == "~" { toks[j].strike += 1 } else if r >= 2 { toks[j].bold += 1; if r >= 3 { toks[j].italic += 1 } } else { toks[j].italic += 1 }
            }
            toks[o].remaining = 0
        }
    }

    // MARK: Tokens

    private func tokens() -> [Tok] {
        var out: [Tok] = []
        var buf = ""
        func flushText() {
            guard !buf.isEmpty else { return }
            out.append(contentsOf: autolinks(decodeEntities(buf)))
            buf = ""
        }
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]

            if c == "\\", i + 1 < n {
                let next = chars[i + 1]
                if "\\`*_{}[]()#+-.!|~<>".contains(next) {
                    buf.append(next)
                    i += 2
                    continue
                }
            }
            if c == "\\", i + 1 == n {
                if !streaming { buf.append(c) }
                i += 1
                continue
            }

            if c == "`" {
                let run = count(of: "`", from: i)
                if let close = findBacktickClose(from: i + run, run: run) {
                    flushText()
                    var code = String(chars[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    out.append(.code(code))
                    i = close + run
                    continue
                }
                // Unclosed: mid-stream the rest is code; otherwise markers next to words are dropped, lone ones stay.
                flushText()
                if streaming {
                    let rest = String(chars[(i + run)...])
                    if !rest.isEmpty { out.append(.code(rest)) }
                    return out
                }
                let before = i > 0 ? chars[i - 1] : " "
                let after = i + run < n ? chars[i + run] : " "
                if before.isWhitespace && after.isWhitespace { buf.append(String(repeating: "`", count: run)) }
                i += run
                continue
            }

            if c == "!" , i + 1 < n, chars[i + 1] == "[", let l = link(at: i + 1) {
                flushText()
                out.append(.link(l.runs.isEmpty ? [ChatRun("image")] : l.runs, l.url))
                i = l.end
                continue
            }

            if c == "[" {
                if let l = link(at: i) {
                    flushText()
                    out.append(l.runs.isEmpty ? .text(l.url) : .link(l.runs, l.url))
                    i = l.end
                    continue
                }
                if streaming, let partial = partialLink(at: i) {
                    // "[label" or "[label](http" while it arrives: the label as plain text, no brackets.
                    flushText()
                    out.append(contentsOf: InlineParser(partial, streaming: true).tokens())
                    return out
                }
            }

            if c == "<", let close = chars[(i + 1)...].firstIndex(of: ">") {
                let inner = String(chars[(i + 1)..<close])
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:"), !inner.contains(" ") {
                    flushText()
                    out.append(.link([ChatRun(inner.hasPrefix("mailto:") ? String(inner.dropFirst(7)) : inner)], inner))
                    i = close + 1
                    continue
                }
            }

            if c == "*" || c == "_" || c == "~" {
                let run = count(of: c, from: i)
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                let next: Character? = i + run < n ? chars[i + run] : nil
                let atEnd = next == nil && streaming
                let prevWS = prev.map { $0.isWhitespace } ?? true
                let nextWS = next.map { $0.isWhitespace } ?? true
                let prevP = prev.map(isPunct) ?? false
                let nextP = next.map(isPunct) ?? false
                let left = !nextWS && (!nextP || prevWS || prevP)
                let right = !prevWS && (!prevP || nextWS || nextP)
                var canOpen = left, canClose = right
                if c == "_" {
                    canOpen = left && (!right || prevP)
                    canClose = right && (!left || nextP)
                }
                if c == "~" && run > 2 { canOpen = false; canClose = false }
                flushText()
                out.append(.delim(char: c, count: run, canOpen: canOpen, canClose: canClose, atEnd: atEnd))
                i += run
                continue
            }

            buf.append(c)
            i += 1
        }
        flushText()
        return out
    }

    private func count(of c: Character, from i: Int) -> Int {
        var j = i
        while j < chars.count, chars[j] == c { j += 1 }
        return j - i
    }

    private func findBacktickClose(from start: Int, run: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "`" {
                let r = count(of: "`", from: j)
                if r == run { return j }
                j += r
            } else {
                j += 1
            }
        }
        return nil
    }

    /// `[label](url)` from `i` (the "["): the label's runs, the url, and the index after ")".
    private func link(at i: Int) -> (runs: [ChatRun], url: String, end: Int)? {
        var depth = 0
        var j = i
        var close: Int?
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "[" { depth += 1 } else if chars[j] == "]" {
                depth -= 1
                if depth == 0 { close = j; break }
            }
            j += 1
        }
        guard let rb = close, rb + 1 < chars.count, chars[rb + 1] == "(" else { return nil }
        var k = rb + 2
        var pd = 1
        while k < chars.count {
            if chars[k] == "(" { pd += 1 } else if chars[k] == ")" { pd -= 1; if pd == 0 { break } }
            k += 1
        }
        guard k < chars.count else { return nil }
        var url = String(chars[(rb + 2)..<k]).trimmingCharacters(in: .whitespaces)
        if let sp = url.firstIndex(of: " ") { url = String(url[..<sp]) }   // [a](url "title")
        if url.hasPrefix("<") && url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
        let label = String(chars[(i + 1)..<rb])
        return (InlineParser(label, streaming: false).runs(), url, k + 1)
    }

    /// While streaming: the label of a link that hasn't closed ("[label", "[label](htt").
    private func partialLink(at i: Int) -> String? {
        let rest = String(chars[(i + 1)...])
        if let rb = rest.firstIndex(of: "]") {
            let after = rest[rest.index(after: rb)...]
            guard after.isEmpty || after.hasPrefix("(") else { return nil }
            if after.hasPrefix("("), after.contains(")") { return nil }
            return String(rest[..<rb])
        }
        guard !rest.contains("\n") else { return nil }
        return rest
    }

    private func isPunct(_ c: Character) -> Bool {
        c.isPunctuation || c.isSymbol
    }

    private func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Bare links in text ("https://muse.studio/docs.") become links; the closing punctuation stays text.
    private func autolinks(_ s: String) -> [Tok] {
        guard s.contains("http://") || s.contains("https://") else { return [.text(s)] }
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#) else { return [.text(s)] }
        let ns = s as NSString
        var out: [Tok] = []
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            let url = ns.substring(with: m.range)
            out.append(.link([ChatRun(url)], url))
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(.text(ns.substring(from: last))) }
        return out
    }
}
