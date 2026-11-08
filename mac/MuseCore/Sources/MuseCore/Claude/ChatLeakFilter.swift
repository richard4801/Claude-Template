import Foundation

/// What the chat may show (plans/claude-chat-mac.md "No leaks"; the Android chat uses the same rules). Claude's text,
/// the user's own messages, tool rows and errors pass through here before they are drawn, so none of the plumbing
/// reaches the screen: system briefs and context lines, raw tool JSON, ids, file paths, stack traces, and (for members)
/// provider, model and GPU names.
public enum ChatLeakFilter {
    public enum Audience: Sendable { case owner, member }

    // MARK: Claude's replies

    /// Claude's text, ready for ChatMarkdown. Safe on partial text mid-stream: an unfinished brief or JSON line is hidden.
    public static func reply(_ text: String, audience: Audience = .owner) -> String {
        var s = stripTaggedBlocks(text)
        s = stripLines(s, dropContext: true)
        s = scrub(s)
        if audience == .member { s = memberWords(s) }
        return tidy(s)
    }

    // MARK: The user's messages

    /// The user's message as they typed it: without the context line the app put in front ("[Suite …]", "[Recreate …]"),
    /// the attached-image paths, or a suggestion's instructions for Claude ("Use get_recipe.").
    public static func userText(_ text: String) -> String {
        var s = stripTaggedBlocks(text)
        // A leading context line in square brackets.
        while s.hasPrefix("["), let nl = s.firstIndex(of: "\n"), contextLine(String(s[s.startIndex..<nl])) {
            s = String(s[s.index(after: nl)...])
        }
        if s.hasPrefix("["), !s.contains("\n"), s.hasSuffix("]"), contextLine(s) { s = "" }
        // The image list ClaudeAttachmentPrompt appends.
        if let r = s.range(of: "Attached images (Read each one):") { s = String(s[..<r.lowerBound]) }
        s = dropToolSentences(s)
        s = scrub(s)
        return tidy(s)
    }

    // MARK: Tool rows

    /// A tool row's one line: its summary without ids or paths, never empty.
    public static func toolSummary(_ summary: String, name: String) -> String {
        let s = tidy(scrub(stripTaggedBlocks(summary)))
        if s.isEmpty || looksLikeJSON(s) { return ClaudeChipText.words(name) }
        return s
    }

    /// The row's expanded line, in plain words: what the step was and how it ended.
    public static func toolDetail(name: String, summary: String, status: ClaudeToolStatus) -> String {
        let what = ClaudeChipText.words(name)
        let shown = toolSummary(summary, name: name)
        let head = shown.caseInsensitiveCompare(what) == .orderedSame ? what : "\(what): \(shown)"
        switch status {
        case .running: return "\(head). Still running."
        case .done: return "\(head). Finished."
        case .error: return "\(head). This step didn't work; Claude usually tries another way."
        }
    }

    // MARK: Errors

    /// A failed turn's error in plain words: what happened and what to do. Never a stack trace, code or path.
    public static func errorWords(_ raw: String?) -> String {
        let r = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let l = r.lowercased()
        if r.isEmpty { return "Claude stopped before finishing. Try again." }
        if l.contains("stopped") || l.contains("interrupt") || l.contains("cancel") || l.contains("aborted") { return "Stopped. Send a message to carry on." }
        if l.contains("isn't ready") || l.contains("not installed") || l.contains("enoent") || l.contains("command not found") {
            return "Claude Code isn't ready on this Mac. Open Settings to set it up, then try again."
        }
        if l.contains("rate limit") || l.contains("usage limit") || l.contains("429") || l.contains("overloaded") || l.contains("quota") {
            return "Your Claude plan has reached its limit for now. Try again in a little while."
        }
        if l.contains("not signed in") || l.contains("login") || l.contains("log in") || l.contains("401") || l.contains("unauthor") || l.contains("auth") {
            return "Claude Code is signed out. Sign in again, then try again."
        }
        if l.contains("offline") || l.contains("network") || l.contains("connection") || l.contains("nsurlerror") || l.contains("-1009")
            || l.contains("econnrefused") || l.contains("enotfound") || l.contains("dns") || l.contains("unreachable") {
            return "Couldn't reach the server. Check your connection, then try again."
        }
        if l.contains("timed out") || l.contains("timeout") || l.contains("took too long") { return "Claude took too long to answer. Try again." }
        if l.contains("turn_expired") || l.contains("expired") { return "That message waited too long and expired. Send it again." }
        let cleaned = tidy(scrub(stripLines(stripTaggedBlocks(r), dropContext: true)))
        let technical = cleaned.isEmpty || cleaned.count > 160 || looksLikeJSON(cleaned) || !MemberText.isSafe(cleaned)
            || cleaned.range(of: #"(?i)\b(error|exception|errno|exit code|status \d{3}|http \d{3}|traceback|panic|fatal|undefined|null|nil)\b"#, options: .regularExpression) != nil
        if technical { return "Claude stopped before finishing. Try again." }
        return cleaned.hasSuffix(".") ? cleaned : cleaned + "."
    }

    // MARK: Pieces

    /// `<system-reminder>…</system-reminder>`, `<thinking>…`, tool-call markup: removed with what they hold. An opening tag
    /// with no closing yet (mid-stream) hides everything after it.
    static func stripTaggedBlocks(_ text: String) -> String {
        guard text.contains("<") else { return text }
        let names = ["system-reminder", "system", "thinking", "context", "brief", "instructions", "muse_context", "suite_context",
                     "tool_use", "tool_result", "function_calls", "function_results", "invoke", "parameter", "env", "command-name",
                     "local-command-stdout", "user-prompt-submit-hook"]
        var s = text
        for name in names {
            while let open = s.range(of: "<\(name)", options: .caseInsensitive) {
                // Only a real tag: "<name>" or "<name attr…>".
                let after = s[open.upperBound...].first
                guard after == ">" || after == " " || after == "\n" || after == nil else { break }
                if let close = s.range(of: "</\(name)>", options: .caseInsensitive, range: open.upperBound..<s.endIndex) {
                    s.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    s.removeSubrange(open.lowerBound...)
                }
            }
        }
        return s
    }

    /// A context line the app put in front: one bracketed line starting with a capital ("[Suite …]", "[Camera session …]",
    /// "[Recreate …]", "[Edit …]"); the same rule as the Android chat (^\[[A-Z][^\]]*\]$).
    private static func contextLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.range(of: #"^\[[A-Z][^\]]*\]$"#, options: .regularExpression) != nil
    }

    /// Line by line: context lines, raw JSON, stack traces. Lines inside a code fence are left alone, except a fence that
    /// holds only tool JSON, which goes as a whole.
    static func stripLines(_ text: String, dropContext: Bool) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var inTrace = false
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            // A fenced block: kept unless it is JSON (tool input or output), which members and owners don't need in chat.
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                let marker = String(t.prefix(3))
                let lang = t.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                var j = i + 1
                var body: [String] = []
                while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(marker) { body.append(lines[j]); j += 1 }
                let joined = body.joined(separator: "\n")
                let isJSON = lang == "json" || lang == "jsonc" || (lang.isEmpty && looksLikeJSON(joined.trimmingCharacters(in: .whitespacesAndNewlines)))
                if isJSON {
                    i = j + 1
                    continue
                }
                out.append(line)
                out.append(contentsOf: body)
                if j < lines.count { out.append(lines[j]) }
                i = j + 1
                continue
            }
            if dropContext, contextLine(t) { i += 1; continue }
            // Raw JSON outside a fence: a whole object or array on its own line, or one still arriving.
            if t.hasPrefix("{\"") || t.hasPrefix("[{\"") || (looksLikeJSON(t) && t.count > 2) { i += 1; continue }
            // Stack traces.
            if isTraceLine(t) || (inTrace && (line.hasPrefix("  ") || line.hasPrefix("\t")) && !t.isEmpty) {
                inTrace = true
                i += 1
                continue
            }
            inTrace = false
            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private static let traceRe = try! NSRegularExpression(pattern: [
        #"^at\s+\S.*[:(]\d+(:\d+)?\)?$"#,                     // JS: at fn (file.js:12:3)
        #"^Traceback \(most recent call last\)"#,              // Python
        #"^File ".+", line \d+"#,                              // Python frame
        #"^\d+\s+\S+\s+0x[0-9a-fA-F]+\s"#,                     // Apple crash frame
        #"^#\d+\s+0x[0-9a-fA-F]+"#,                            // gdb/lldb frame
        #"^(Fatal error|Thread \d+ Crashed|Exception Type|Uncaught|UnhandledPromiseRejection)"#,
        #"^\w*(Error|Exception): .+ at .+:\d+"#,
        #"^\s*node:internal/"#,
    ].joined(separator: "|"))

    private static func isTraceLine(_ t: String) -> Bool {
        traceRe.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    static func looksLikeJSON(_ t: String) -> Bool {
        guard (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]") && t.contains("{")) else { return false }
        guard let d = t.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) != nil
    }

    // Ids, paths and tool names inside a line.
    private static let pathRe = try! NSRegularExpression(
        pattern: #"(?<![\w.:/~-])(?:~|/(?:Users|home|private|var|tmp|opt|Volumes|Library|Applications|usr|etc|srv|app|workspace|root|mnt))(?:/[^\s/`'"()<>\[\],;]+)+/?|[A-Za-z]:\\(?:[^\s\\]+\\)*[^\s\\]+"#)
    private static let mcpRe = try! NSRegularExpression(pattern: #"\bmcp__[A-Za-z0-9_-]+"#)
    private static let uploadIdRe = try! NSRegularExpression(pattern: #"\s*\((?:upload ?id|id|thread|session|turn)[: ]+[A-Za-z0-9_-]*\d[A-Za-z0-9_-]*\)"#, options: .caseInsensitive)
    private static let uuidRe = try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)
    /// "cs_1a2b3c", "up_1", "toolu_01ABC", "ses_x9": a short lowercase prefix, an underscore, and letters with digits.
    private static let idRe = try! NSRegularExpression(pattern: #"`?\b(?:[a-z]{1,8}_)+(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{1,40}\b`?"#)
    private static let hexRe = try! NSRegularExpression(pattern: #"\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{16,}\b"#)
    private static let labelledIdRe = try! NSRegularExpression(pattern: #"(?i)\b(?:upload ?id|thread ?id|session ?id|turn ?id|id)\s*[:=]?\s*$"#)

    /// Removes paths, ids and MCP tool names from running text (code blocks keep paths: a script needs them).
    static func scrub(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var inFence = false
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
            var s = lines[i]
            s = replace(mcpRe, in: s) { ClaudeChipText.words($0).lowercased() }
            s = replace(uploadIdRe, in: s) { _ in "" }
            if !inFence {
                s = replace(pathRe, in: s) { m in
                    // A full stop or comma after the path is the sentence's, not the file's.
                    let tail = String(m.reversed().prefix { ".,;:!?".contains($0) }.reversed())
                    return fileName(String(m.dropLast(tail.count))) + tail
                }
            }
            s = replace(uuidRe, in: s) { _ in "" }
            s = replace(hexRe, in: s) { _ in "" }
            s = replace(idRe, in: s) { _ in "" }
            // "with id" / "uploadId:" left dangling at the end of a phrase.
            s = replace(labelledIdRe, in: s) { _ in "" }
            lines[i] = s
        }
        return lines.joined(separator: "\n")
    }

    /// A path shown as its file name when that reads as a name ("Final cut.mp4"), else "a file on this Mac".
    private static func fileName(_ path: String) -> String {
        let last = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let stem = (last as NSString).deletingPathExtension
        let ext = (last as NSString).pathExtension
        let idLike = stem.range(of: #"^(?:[a-z]{1,8}_)+[A-Za-z0-9]*\d|^[0-9a-fA-F-]{12,}$|^\d+$"#, options: .regularExpression) != nil
        if last.isEmpty || ext.isEmpty || idLike || stem.count > 48 { return "a file on this Mac" }
        return last
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with f: (String) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// A suggestion chip's instructions for Claude ("Use get_recipe.", "with match_slots and apply_recipe") aren't the
    /// owner's words: sentences naming a tool are dropped from the bubble (Claude still gets them).
    private static func dropToolSentences(_ text: String) -> String {
        let tool = try! NSRegularExpression(pattern: #"\b[a-z]+(?:_[a-z]+)+\b"#)
        guard tool.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return text }
        var kept: [String] = []
        for sentence in sentences(text) where tool.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) == nil {
            kept.append(sentence)
        }
        let joined = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? text : joined
    }

    /// Sentences with their trailing space: split after ". ", "? ", "! " and at line ends.
    private static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            cur.append(c)
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "\n" || ((c == "." || c == "?" || c == "!") && (next == nil || next == " " || next == "\n")) {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Members never see provider, model or GPU names (plans/design-direction.md §7).
    private static let modelIdRe = try! NSRegularExpression(
        pattern: #"(?i)\b(?:claude|gpt|o\d|gemini|llama|seedance|kling|veo|wan|hailuo|sora|runway|gen-?\d|luma|ray|flux|sdxl|qwen|minimax|hunyuan|ltx|pika)[-_ ]?(?:[a-z]*[-_.]?)?\d[\w.-]*"#)
    private static let providerRe = try! NSRegularExpression(
        pattern: #"(?i)\b(?:anthropic|openai|google deepmind|higgsfield|fal\.ai|replicate|runpod|together\.ai|bytedance|kuaishou|seedance|kling|runway|luma ai|elevenlabs|minimax|hailuo|stability ai|black forest labs|nvidia|a100|h100|h200|l40s?|rtx ?\d{4}|gpus?)\b"#)

    private static func memberWords(_ s: String) -> String {
        var out = replace(modelIdRe, in: s) { _ in "the model" }
        out = replace(providerRe, in: out) { _ in "the studio" }
        // "the studio's the model" style doubles read badly: collapse the obvious ones.
        out = out.replacingOccurrences(of: "the studio the model", with: "the model").replacingOccurrences(of: "the model the model", with: "the model")
        return out
    }

    /// Spaces and empty lines left where something was removed; whitespace inside code fences is kept.
    static func tidy(_ s: String) -> String {
        var lines: [String] = []
        var inFence = false
        var blank = 0
        for raw in s.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); blank = 0; lines.append(raw); continue }
            if inFence { lines.append(raw); continue }
            if t.isEmpty {
                blank += 1
                if blank <= 1, !lines.isEmpty { lines.append("") }
                continue
            }
            blank = 0
            // Collapse doubled spaces and spaces before punctuation, keeping the line's indent (lists nest by it).
            let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
            var body = String(raw.dropFirst(indent.count))
            while body.contains("  ") { body = body.replacingOccurrences(of: "  ", with: " ") }
            for p in [" .", " ,", " ;", " :", " )"] where body.contains(p) { body = body.replacingOccurrences(of: p, with: String(p.dropFirst())) }
            body = body.replacingOccurrences(of: "( ", with: "(").replacingOccurrences(of: " ()", with: "")
            lines.append(indent + body.trimmingCharacters(in: .whitespaces))
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
