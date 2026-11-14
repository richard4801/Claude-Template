import Foundation

// Auto-compact for MUSE's Claude (owner, 2026-11-14). A long Edit chat about a song's captions died with "Prompt is too long ·
// automatic compaction failed: API Error: Output blocked by content filtering policy": Claude Code's own summary quoted the
// lyrics, the filter blocked it, and every retry of the chat failed the same way. Two layers, both run by MUSE:
// 1. Preventive: once a resumed chat passes 75% of its model's context, MUSE runs `/compact <MUSE's instructions>` before the
//    next message (verified headless with `-p --input-format stream-json`, Claude Code 2.1.325: a `system/compact_boundary`
//    line, then a success result on the same session). The instructions keep ids, decisions and style notes and never quote
//    lyrics or other long third-party text.
// 2. Recovery: a turn that ends "prompt too long / compaction failed" starts a fresh Claude Code session for the same chat,
//    seeded with MUSE's own handoff (title, recent messages with lyrics and long quotes cut, memory, the same rules), and the
//    person's message goes again once. One recovery per turn; if it fails again the chat says so plainly with New chat.

/// How full a chat's Claude Code context is, from the stream.
public struct ClaudeContextUsage: Codable, Hashable, Sendable {
    /// Tokens the last request sent plus what it wrote (input + cache reads + cache writes + output).
    public var tokens: Int
    /// The model's context window when Claude Code reported it (`result.modelUsage.<model>.contextWindow`).
    public var window: Int?
    public var model: String?

    public init(tokens: Int, window: Int? = nil, model: String? = nil) {
        self.tokens = tokens
        self.window = window
        self.model = model
    }

    /// The window used for the threshold: the reported one, else by the model's name.
    public var effectiveWindow: Int { (window ?? 0) > 0 ? window! : ClaudeAutoCompact.window(model: model) }
    public var fraction: Double { Double(tokens) / Double(max(1, effectiveWindow)) }
}

/// Reads the context numbers out of Claude Code's stream lines (the typed parser ignores them).
public struct ClaudeContextMeter: Sendable {
    public private(set) var tokens: Int?
    public private(set) var window: Int?
    public private(set) var model: String?
    /// A `/compact` finished (`system/compact_boundary`); its `post_tokens` when given.
    public private(set) var compacted = false
    public private(set) var resultOk: Bool?

    public init() {}

    public var usage: ClaudeContextUsage? {
        guard let tokens else { return nil }
        return ClaudeContextUsage(tokens: tokens, window: window, model: model)
    }

    public mutating func read(_ line: String) {
        // Most lines are text deltas: skip the JSON parse unless the line can carry what we want.
        guard line.contains("usage") || line.contains("compact_boundary") || line.contains("\"result\"") || line.contains("\"init\"") else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let json = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)), case .object(let o) = json else { return }
        switch o.jStr("type") {
        case "system":
            if o.jStr("subtype") == "init", let m = o.jStr("model") { model = m }
            if o.jStr("subtype") == "compact_boundary" {
                compacted = true
                if case .object(let meta)? = o["compact_metadata"], let post = meta.jNum("post_tokens") { tokens = Int(post) }
            }
        case "assistant":
            guard case .object(let msg)? = o["message"], case .object(let u)? = msg["usage"] else { return }
            if let m = msg.jStr("model"), m != "<synthetic>" { model = m }
            let total = Self.sum(u)
            if total > 0 { tokens = total }
        case "result":
            var isError = false
            if case .bool(let e)? = o["is_error"] { isError = e }
            resultOk = !isError && o.jStr("subtype") == "success"
            if case .object(let mu)? = o["modelUsage"] {
                var best: Int?
                for (name, v) in mu {
                    guard case .object(let entry) = v, let w = entry.jNum("contextWindow"), w > 0 else { continue }
                    if name == model { best = Int(w); break }
                    best = max(best ?? 0, Int(w))
                }
                if let best { window = best }
            }
        default:
            return
        }
    }

    static func sum(_ u: [String: JSONValue]) -> Int {
        ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].reduce(0) { $0 + Int(u.jNum($1) ?? 0) }
    }
}

public enum ClaudeAutoCompact {
    /// Compact before the next message once this much of the window is used.
    public static let threshold = 0.75
    /// The line the chat shows when a full chat carried on in a fresh session.
    public static let freshSpaceLine = "This chat was full, so Claude carried on in a fresh space with a summary."
    /// The quiet line goes in as a tool step with this id prefix (the chat draws it as a plain line, not a chip).
    public static let freshSpacePrefix = "muse_fresh_"
    /// The turn's error when even the fresh space didn't fit (the chat offers New chat).
    public static let fullError = "This chat is too full to carry on. Start a new chat to keep going."

    /// What Claude keeps (and never quotes) when its conversation is summarised, by `/compact` or by MUSE's handoff.
    public static let keepRules = """
    Keep: the MUSE ids this chat works on (edit session, project, clip, track and item ids), what is in the edit now, the \
    decisions made and why, anything waiting for the person's approval, and the person's style notes and preferences. \
    NEVER quote song lyrics, poems, scripts or any other long third-party text, not even a line: refer to it by where it \
    is stored in MUSE (for captions, the captions track id and item ids, with their times). Paraphrase, don't quote.
    """

    /// Claude Code's own compact, with MUSE's instructions (one stdin message).
    public static var compactCommand: String { "/compact " + keepRules.replacingOccurrences(of: "\n", with: " ") }

    /// The model's context window when Claude Code didn't say: 1M for the `[1m]` variants, else 200k (the smaller, safe guess).
    public static func window(model: String?) -> Int {
        guard let m = model?.lowercased() else { return 200_000 }
        return m.contains("[1m]") || m.hasSuffix("-1m") ? 1_000_000 : 200_000
    }

    /// Whether to compact before the next message: a resumed chat past the threshold.
    public static func shouldCompact(_ usage: ClaudeContextUsage?, resuming: Bool) -> Bool {
        guard resuming, let usage, usage.tokens > 0 else { return false }
        return usage.fraction >= threshold
    }

    /// A turn's error that means the conversation no longer fits (or Claude Code's own compact failed).
    public static func isContextOverflow(_ error: String?) -> Bool {
        guard let l = error?.lowercased(), !l.isEmpty else { return false }
        return l.contains("prompt is too long") || l.contains("compaction failed") || l.contains("context window")
            || l.contains("context length") || l.contains("input is too long") || l.contains("exceed context limit")
            || l.contains("conversation is too long") || l.contains("too full to carry on")
    }

    // MARK: The handoff

    /// How many recent messages the handoff carries, and how long each may be.
    public static let handoffMessages = 10
    public static let handoffMessageChars = 500

    /// The first message of a fresh session: what the chat was about, in MUSE's words, without lyrics or long quotes.
    /// `excluding` is the person's message that will follow it (not repeated in the recent list).
    public static func handoff(title: String?, contextKind: String?, contextId: String?, messages: [ClaudeMessage],
                               memory: [ClaudeMemoryRule] = [], excluding latest: String? = nil) -> String {
        var talk = messages.filter { ($0.role == "user" || $0.role == "assistant") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let latest, let last = talk.last, last.role == "user",
           ClaudeSessions.typedText(last.text) == ClaudeSessions.typedText(latest) { talk.removeLast() }
        let recent = talk.suffix(handoffMessages)
        var out = ["[MUSE handoff] This chat got too long for one Claude Code session, so it carries on here. The earlier "
            + "conversation is summarised below by MUSE. Read the current state from MUSE's tools before changing anything."]
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { out.append("Chat: \(elide(t, limit: 120))") }
        if let k = contextKind, let id = contextId, !k.isEmpty, !id.isEmpty { out.append("Working on: \(k) \(id)") }
        if !recent.isEmpty {
            out.append("Recent messages (lyrics, long quotes and lists left out; they are stored in MUSE):")
            for m in recent {
                let who = m.role == "user" ? "Person" : "Claude"
                let text = m.role == "user" ? ClaudeSessions.typedText(m.text) : m.text
                out.append("- \(who): \(elide(text, limit: handoffMessageChars))")
            }
        }
        let rules = memory.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(30)
        if !rules.isEmpty {
            out.append("The person's memory:")
            for r in rules { out.append("- \(elide(r, limit: 240))") }
        }
        out.append(keepRules.replacingOccurrences(of: "Keep:", with: "Carry on keeping:"))
        out.append("The person's message follows.")
        return out.joined(separator: "\n")
    }

    /// One message, safe to carry: code blocks, block quotes, runs of short lines (verses, caption lists) and long quoted
    /// spans are left out, then it is cut to `limit` characters on one line.
    public static func elide(_ text: String, limit: Int = handoffMessageChars) -> String {
        var lines: [String] = []
        var inFence = false
        var fenced = false
        for raw in text.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("```") || l.hasPrefix("~~~") {
                if !inFence { fenced = true }
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if fenced { lines.append("[block left out]"); fenced = false }
            if l.hasPrefix(">") { if lines.last != "[quote left out]" { lines.append("[quote left out]") }; continue }
            lines.append(l)
        }
        if fenced { lines.append("[block left out]") }
        // Runs of short lines (a verse, a caption list) are left out as a whole: 3 or more, or 2 that aren't both
        // sentences ending in a full stop ("Make it pink.\nThanks." stays).
        var kept: [String] = []
        var i = 0
        while i < lines.count {
            var j = i
            while j < lines.count, isShortLine(lines[j]) { j += 1 }
            let run = j - i
            if run >= 3 || (run == 2 && !(lines[i].hasSuffix(".") && lines[i + 1].hasSuffix("."))) {
                kept.append("[\(run) short lines left out]")
                i = j
            } else {
                if !lines[i].isEmpty { kept.append(lines[i]) }
                i += 1
            }
        }
        var s = kept.joined(separator: " ")
        s = cutQuotes(s)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if s.count > limit { s = String(s.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" }
        return s
    }

    /// A line that reads like a verse or a list item rather than a sentence of talk.
    static func isShortLine(_ l: String) -> Bool {
        // "[… left out]" markers and a line that introduces what follows ("…on track ct_caps (items ci_1 to ci_4):") stay.
        guard !l.isEmpty, !l.hasPrefix("["), !l.hasSuffix(":") else { return false }
        return l.count <= 80
    }

    /// Quoted spans longer than 30 characters ("…", “…”, '…' is left alone: apostrophes) become [quote left out].
    static func cutQuotes(_ s: String) -> String {
        var r = s
        for pattern in [#""[^"]{30,}""#, #"“[^”]{30,}”"#, #"«[^»]{30,}»"#] {
            r = r.replacingOccurrences(of: pattern, with: "[quote left out]", options: .regularExpression)
        }
        return r
    }
}
