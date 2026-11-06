import Foundation

/// One line of Claude Code's `--output-format stream-json --verbose --include-partial-messages`, typed.
/// Anything MUSE doesn't use is `.ignored`; a line that isn't JSON is `.ignored` too (never a crash).
public enum ClaudeStreamEvent: Hashable, Sendable {
    public struct McpServer: Hashable, Sendable {
        public var name: String
        public var status: String
        public init(name: String, status: String) {
            self.name = name
            self.status = status
        }
    }

    public struct ToolResultImage: Hashable, Sendable {
        /// base64
        public var data: String
        public var mimeType: String
        public init(data: String, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    /// `system` / `init`.
    case initialized(sessionId: String?, model: String?, tools: [String], mcpServers: [McpServer])
    /// `stream_event` → `content_block_delta` / `text_delta`.
    case textDelta(String)
    /// A text block of a complete `assistant` message.
    case assistantText(messageId: String?, text: String)
    /// A `tool_use` block of an `assistant` message.
    case toolUse(id: String, name: String, input: JSONValue?)
    /// A `tool_result` block of a `user` message.
    case toolResult(toolUseId: String, isError: Bool, text: String, images: [ToolResultImage])
    /// The final `result`.
    case result(ok: Bool, subtype: String, text: String?, sessionId: String?, costUsd: Double?)
    case ignored
}

public enum ClaudeStreamParser {
    /// One stdout line → its events (an `assistant` line can carry several blocks).
    public static func parse(_ line: String) -> [ClaudeStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let json = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)), case .object(let o) = json else {
            return [.ignored]
        }
        switch o.jStr("type") {
        case "system":
            guard o.jStr("subtype") == "init" else { return [.ignored] }
            let tools = o.jArr("tools").compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
            let servers = o.jArr("mcp_servers").compactMap { v -> ClaudeStreamEvent.McpServer? in
                guard case .object(let s) = v, let name = s.jStr("name") else { return nil }
                return .init(name: name, status: s.jStr("status") ?? "unknown")
            }
            return [.initialized(sessionId: o.jStr("session_id"), model: o.jStr("model"), tools: tools, mcpServers: servers)]
        case "stream_event":
            guard case .object(let ev)? = o["event"], ev.jStr("type") == "content_block_delta", case .object(let delta)? = ev["delta"],
                  delta.jStr("type") == "text_delta", let text = delta.jStr("text"), !text.isEmpty else { return [.ignored] }
            return [.textDelta(text)]
        case "assistant":
            guard case .object(let msg)? = o["message"] else { return [.ignored] }
            let id = msg.jStr("id")
            let out = msg.jArr("content").compactMap { block -> ClaudeStreamEvent? in
                guard case .object(let b) = block else { return nil }
                switch b.jStr("type") {
                case "text":
                    guard let t = b.jStr("text"), !t.isEmpty else { return nil }
                    return .assistantText(messageId: id, text: t)
                case "tool_use":
                    guard let tid = b.jStr("id"), let name = b.jStr("name") else { return nil }
                    return .toolUse(id: tid, name: name, input: b["input"])
                default:
                    return nil
                }
            }
            return out.isEmpty ? [.ignored] : out
        case "user":
            guard case .object(let msg)? = o["message"] else { return [.ignored] }
            let out = msg.jArr("content").compactMap { block -> ClaudeStreamEvent? in
                guard case .object(let b) = block, b.jStr("type") == "tool_result", let tid = b.jStr("tool_use_id") else { return nil }
                var isError = false
                if case .bool(let e)? = b["is_error"] { isError = e }
                var texts: [String] = []
                var images: [ClaudeStreamEvent.ToolResultImage] = []
                switch b["content"] {
                case .string(let s)?: texts.append(s)
                case .array(let parts)?:
                    for p in parts {
                        guard case .object(let part) = p else { continue }
                        switch part.jStr("type") {
                        case "text": if let s = part.jStr("text") { texts.append(s) }
                        case "image":
                            // Anthropic shape {source: {type: base64, media_type, data}}; MCP shape {data, mimeType}.
                            if case .object(let src)? = part["source"], let data = src.jStr("data") {
                                images.append(.init(data: data, mimeType: src.jStr("media_type") ?? "image/png"))
                            } else if let data = part.jStr("data") {
                                images.append(.init(data: data, mimeType: part.jStr("mimeType") ?? part.jStr("media_type") ?? "image/png"))
                            }
                        default: break
                        }
                    }
                default: break
                }
                return .toolResult(toolUseId: tid, isError: isError, text: texts.joined(separator: "\n"), images: images)
            }
            return out.isEmpty ? [.ignored] : out
        case "result":
            var isError = false
            if case .bool(let e)? = o["is_error"] { isError = e }
            let subtype = o.jStr("subtype") ?? "unknown"
            var cost: Double?
            if case .number(let n)? = o["total_cost_usd"] { cost = n }
            return [.result(ok: !isError && subtype == "success", subtype: subtype, text: o.jStr("result"), sessionId: o.jStr("session_id"), costUsd: cost)]
        default:
            return [.ignored]
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func jStr(_ k: String) -> String? { if case .string(let s)? = self[k] { return s }; return nil }
    func jArr(_ k: String) -> [JSONValue] { if case .array(let a)? = self[k] { return a }; return [] }
    func jNum(_ k: String) -> Double? { if case .number(let n)? = self[k] { return n }; return nil }
}
