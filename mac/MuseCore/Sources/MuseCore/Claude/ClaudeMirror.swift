import Foundation

/// Claude Code's stream → the contract's ClaudeEvents (what the Mac shows and mirrors to the server).
/// Stateful: it remembers each tool's name and input so the result's chip can say what happened.
public struct ClaudeEventMapper: Sendable {
    public private(set) var sessionId: String?
    public private(set) var model: String?
    public private(set) var finished: ClaudeEvent?
    public private(set) var mcpServers: [ClaudeStreamEvent.McpServer] = []
    private var tools: [String: (name: String, input: JSONValue?)] = [:]

    public init() {}

    public mutating func map(_ e: ClaudeStreamEvent) -> [ClaudeEvent] {
        switch e {
        case .initialized(let sid, let model, _, let servers):
            if let sid { sessionId = sid }
            if let model { self.model = model }
            mcpServers = servers
            // Blender's server didn't start (uvx couldn't fetch it, or it timed out): say so in the chat, not only to Claude.
            if servers.contains(where: { $0.name == "blender" && $0.status == "failed" }) {
                return [.tool(id: ClaudeCommand.Blender.failedChipId, name: "Blender", status: .error, summary: ClaudeCommand.Blender.didntStart, input: nil)]
            }
            return []
        case .textDelta(let t):
            return [.text(delta: t)]
        case .assistantText(_, let text):
            return [.assistant(text: text)]
        case .toolUse(let id, let name, let input):
            tools[id] = (name, input)
            return [.tool(id: id, name: ClaudeChipText.shortName(name), status: .running, summary: ClaudeChipText.summary(tool: name, input: input), input: input)]
        case .toolResult(let id, let isError, let text, let images):
            let known = tools[id]
            let name = known?.name ?? "tool"
            var out: [ClaudeEvent] = [.tool(id: id, name: ClaudeChipText.shortName(name), status: isError ? .error : .done,
                                            summary: ClaudeChipText.summary(tool: name, input: known?.input, result: text, isError: isError), input: nil)]
            for img in images where Self.decodedSize(img.data) <= ClaudeEvent.maxImageBytes {
                out.append(.image(data: img.data, mimeType: img.mimeType == "image/jpeg" ? "image/jpeg" : "image/png"))
            }
            return out
        case .result(let ok, let subtype, let text, let sid, _):
            if let sid { sessionId = sid }
            let error: String? = ok ? nil : Self.errorText(subtype: subtype, text: text)
            let done = ClaudeEvent.done(ok: ok, error: error, model: model)
            finished = done
            return [done]
        case .ignored:
            return []
        }
    }

    /// The turn ended without a `result` (stopped, crashed, or Claude Code refused to start).
    public mutating func finishWithoutResult(stopped: Bool, exitCode: Int32, stderr: String) -> ClaudeEvent {
        let msg: String
        if stopped {
            msg = "Stopped"
        } else if let line = stderr.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) {
            msg = "Claude Code stopped: \(line.prefix(200))"
        } else {
            msg = "Claude Code stopped (exit \(exitCode))"
        }
        let done = ClaudeEvent.done(ok: false, error: msg, model: model)
        finished = done
        return done
    }

    static func errorText(subtype: String, text: String?) -> String {
        switch subtype {
        case "error_max_turns": return "Claude hit its step limit for this turn"
        case "error_during_execution": return text?.isEmpty == false ? text! : "Claude Code ran into an error"
        default: return text?.isEmpty == false ? text! : "Claude Code: \(subtype)"
        }
    }

    static func decodedSize(_ b64: String) -> Int { b64.utf8.count / 4 * 3 }
}

/// Collects a turn's events and hands them out in batches for POST …/events: consecutive text deltas are merged, and a
/// batch never goes over `maxBytes` (4 MB on the server; one image is ≤ 2 MB of base64 + a little JSON).
public struct ClaudeEventBatcher: Sendable {
    public static let serverLimit = 4 * 1024 * 1024
    public let maxBytes: Int
    public private(set) var pending: [ClaudeEvent] = []

    public init(maxBytes: Int = ClaudeEventBatcher.serverLimit - 64 * 1024) { self.maxBytes = maxBytes }

    public var isEmpty: Bool { pending.isEmpty }

    public mutating func add(_ e: ClaudeEvent) {
        if case .text(let d) = e, case .text(let prev)? = pending.last {
            pending[pending.count - 1] = .text(delta: prev + d)
        } else {
            pending.append(e)
        }
    }

    /// Everything pending, split so each batch's JSON fits.
    public mutating func drain(turnId: String?) -> [ClaudeEventBatch] {
        guard !pending.isEmpty else { return [] }
        var out: [ClaudeEventBatch] = []
        var cur: [ClaudeEvent] = []
        var size = 64
        for e in pending {
            let n = Self.size(e)
            if !cur.isEmpty, size + n > maxBytes {
                out.append(ClaudeEventBatch(turnId: turnId, events: cur))
                cur = []
                size = 64
            }
            cur.append(e)
            size += n
        }
        if !cur.isEmpty { out.append(ClaudeEventBatch(turnId: turnId, events: cur)) }
        pending = []
        return out
    }

    static func size(_ e: ClaudeEvent) -> Int { ((try? JSONEncoder().encode(e))?.count ?? 0) + 1 }
}

/// The MCP session token, kept until 5 minutes before it expires.
public actor ClaudeTokenCache {
    private var current: McpSessionToken?
    private let now: @Sendable () -> Double

    public init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.now = now }

    public func token(_ api: any ClaudeAPI) async throws -> McpSessionToken {
        if let c = current, c.fresh(now: now()) { return c }
        let t = try await api.mcpSessionToken(ttlMinutes: 240)
        current = t
        return t
    }

    public func clear() { current = nil }
}
