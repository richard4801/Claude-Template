import Foundation

/// A small memo table with a size cap: when full it empties and starts again (cheap, and never grows past `limit`).
public final class BoundedMemo<Key: Hashable, Value>: @unchecked Sendable {
    public let limit: Int
    private var table: [Key: Value] = [:]
    private let lock = NSLock()
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return table.count }

    public func value(_ key: Key, _ make: () -> Value) -> Value {
        lock.lock()
        if let v = table[key] { hits += 1; lock.unlock(); return v }
        lock.unlock()
        let v = make()
        lock.lock()
        misses += 1
        if table.count >= limit { table.removeAll(keepingCapacity: true) }
        table[key] = v
        lock.unlock()
        return v
    }
}

/// Performance (build 704 "it lags"): the chat rebuilt every row on each change of the transcript, running the leak
/// filter's regexes over every message and re-parsing every reply's markdown as rows scrolled back in. The results only
/// depend on the text, so they are kept (by text) here. The reply still being written is never kept (it changes on each
/// token; caching it would only fill the table).
public enum ChatTextCache {
    private struct ReplyKey: Hashable { let text: String; let member: Bool }
    private struct ToolKey: Hashable { let summary: String; let name: String }
    private static let replies = BoundedMemo<ReplyKey, String>(limit: 800)
    private static let users = BoundedMemo<String, String>(limit: 400)
    private static let tools = BoundedMemo<ToolKey, String>(limit: 800)
    private static let blocks = BoundedMemo<String, [ChatBlock]>(limit: 400)

    public static func reply(_ text: String, audience: ChatLeakFilter.Audience, streaming: Bool = false) -> String {
        if streaming { return ChatLeakFilter.reply(text, audience: audience) }
        return replies.value(ReplyKey(text: text, member: audience == .member)) { ChatLeakFilter.reply(text, audience: audience) }
    }

    public static func userText(_ text: String) -> String {
        users.value(text) { ChatLeakFilter.userText(text) }
    }

    public static func toolSummary(_ summary: String, name: String) -> String {
        tools.value(ToolKey(summary: summary, name: name)) { ChatLeakFilter.toolSummary(summary, name: name) }
    }

    public static func markdown(_ text: String, streaming: Bool) -> [ChatBlock] {
        if streaming { return ChatMarkdown.parse(text, streaming: true) }
        return blocks.value(text) { ChatMarkdown.parse(text) }
    }
}
