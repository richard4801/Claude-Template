import Foundation

/// Claude chat sessions (WS18): each place keeps its own list of chats on the server, so the owner can start a new one,
/// switch between them, rename and delete them, and pick up where they left off on any device. The AI Suite keeps one
/// list per composer tool (Shot, Photo, Talking, UGC ad, Storyboard, Swap, Recast, Extend); Recreate, Edit and Camera one
/// per reference, editor session or camera. Pure rules, the same as the server's (camera/claude.ts) and Android's.
public enum ClaudeSessions {
    /// The AI Suite's list for a composer tool.
    public static func suiteKey(_ tool: String) -> String {
        let ok = !tool.isEmpty && tool.count <= 20 && tool.allSatisfy { $0.isASCII && $0.isLowercase }
        return "suite:\(ok ? tool : "shot")"
    }

    /// Recreate, Edit and Camera: the list of chats about one reference, editor session or camera.
    public static func contextKey(kind: String, id: String) -> String { "\(kind):\(id)" }

    /// What a chat is called in the list: its name, else "New chat".
    public static func displayTitle(_ t: ClaudeThread) -> String {
        let s = (t.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "New chat" : s
    }

    /// A chat with nothing said yet (New chat on it again does nothing).
    public static func isEmpty(_ t: ClaudeThread) -> Bool { (t.messageCount ?? 0) == 0 && (t.title ?? "").isEmpty }

    /// The automatic title from a first message: the app's context line, ids and paths left out, one line, at most 60
    /// characters cut at a word (the server names chats the same way).
    public static func autoTitle(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, isContextLine(first) { lines.removeFirst() }
        var s = lines.joined(separator: " ")
        for pattern in [#"<[^>]{0,200}>"#, #"\b(?:sa|ct|cm|tu|es|cs|tk|up|img)_[A-Za-z0-9]{4,}\b"#,
                        #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, #"(?:~|/)[\w.-]*/[\w./-]+"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.count > 60 {
            let cut = String(s.prefix(60))
            let head = cut.lastIndex(of: " ").map { cut.distance(from: cut.startIndex, to: $0) > 30 ? String(cut[..<$0]) : cut } ?? cut
            s = head.replacingOccurrences(of: #"[\s,.;:–-]+$"#, with: "", options: .regularExpression) + "…"
        }
        return s
    }

    /// `[Suite …]`, `[Recreate …]`: the line the app puts in front of a message for Claude.
    public static func isContextLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[") && t.hasSuffix("]")
    }

    /// What the owner typed, without the context line(s) in front (how a user message is matched and shown).
    public static func typedText(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.count > 1, let first = lines.first, isContextLine(first) { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When a chat was last used, in the list: "Just now", "5 min ago", "3 h ago", "Yesterday", "4 days ago", then the date.
    public static func lastUsed(_ ms: Double, now: Double = Date().timeIntervalSince1970 * 1000, calendar: Calendar = .current) -> String {
        let s = max(0, (now - ms) / 1000)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        let then = Date(timeIntervalSince1970: ms / 1000), today = Date(timeIntervalSince1970: now / 1000)
        if calendar.isDate(then, inSameDayAs: today) { return "\(Int(s / 3600)) h ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: then), to: calendar.startOfDay(for: today)).day ?? 0
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = calendar.isDate(then, equalTo: today, toGranularity: .year) ? "d MMM" : "d MMM yyyy"
        return f.string(from: then)
    }

    /// The chat to open in a place: the one picked before (if it is still there), else the newest.
    public static func pick(_ list: [ClaudeThread], preferred: String?) -> ClaudeThread? {
        if let p = preferred, let t = list.first(where: { $0.id == p }) { return t }
        return list.max { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
    }

    /// After a delete: the next chat in the list (newer first), or nil when it was the last one.
    public static func after(deleting id: String, in list: [ClaudeThread]) -> ClaudeThread? {
        let rest = list.filter { $0.id != id }
        return rest.max { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
    }

    /// A thread's change (live `{op: "thread"}`, a rename, a new chat) merged into a list, newest first.
    public static func upsert(_ t: ClaudeThread, into list: inout [ClaudeThread]) {
        if let i = list.firstIndex(where: { $0.id == t.id }) {
            var n = t
            if n.messageCount == nil { n.messageCount = list[i].messageCount }
            list[i] = n
        } else {
            list.append(t)
        }
        list.sort { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }
}
