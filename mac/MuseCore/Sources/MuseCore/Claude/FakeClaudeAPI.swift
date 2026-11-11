import Foundation

/// An in-process ClaudeAPI for demo mode, previews and tests. It stores mirrored events as messages like the server
/// (`user`, `assistant`, `tool`, `image`; text deltas are only relayed), queues phone turns, and emits `claude` live events.
public final class FakeClaudeAPI: ClaudeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [String: ClaudeThread] = [:]
    private var messages: [String: [ClaudeMessage]] = [:]
    private var turns: [String: ClaudeTurn] = [:]
    private var listeners: [UUID: AsyncStream<ClaudeLiveEvent>.Continuation] = [:]
    private var counter = 0
    private var fallback = ClaudeApiFallback(available: true, enabled: false)
    private var info = ClaudeCodeInfo()
    private var lastBeat: Double = 0

    // Recorded for tests.
    public private(set) var posted: [(threadId: String, batch: ClaudeEventBatch)] = []
    public private(set) var claims: [String] = []
    public private(set) var heartbeats: [ClaudeCodeInfo] = []
    public private(set) var tokensMinted = 0
    public var now: () -> Double
    public var base = "https://muse.test"
    /// Make claims fail with this code (`already_claimed`, `turn_expired`).
    public var claimError: String?

    public init(now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.now = now }

    private func locked<T>(_ f: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try f()
    }

    private func nextId(_ p: String) -> String {
        counter += 1
        return "\(p)_\(String(counter, radix: 36))\(String(repeating: "0", count: 3))"
    }

    private func emit(_ e: ClaudeLiveEvent) {
        let ls = locked { Array(listeners.values) }
        for l in ls { l.yield(e) }
    }

    public var allPostedEvents: [ClaudeEvent] { locked { posted.flatMap(\.batch.events) } }

    // MARK: ClaudeAPI

    public func status() async throws -> ClaudeStatus {
        locked {
            ClaudeStatus(mac: ClaudeMacStatus(online: now() - lastBeat < 45_000, claudeCode: info,
                                              answeringTurn: turns.values.first { $0.state == "running" }?.id),
                         apiFallback: fallback, connectorUrl: "\(base)/mcp", openInClaudeUrl: "https://claude.ai/new")
        }
    }

    public func setApiFallback(_ on: Bool) async throws -> ClaudeStatus {
        locked { fallback.enabled = on }
        let s = try await status()
        emit(.status(s))
        return s
    }

    public func heartbeat(_ info: ClaudeCodeInfo) async throws -> ClaudeHeartbeatReply {
        locked {
            self.info = info
            lastBeat = now()
            heartbeats.append(info)
            return ClaudeHeartbeatReply(ok: true, pending: turns.values.filter { $0.state == "queued" }.sorted { $0.createdAt < $1.createdAt })
        }
    }

    public func thread(contextKind: String, contextId: String) async throws -> ClaudeThread {
        try await thread(contextKind: contextKind, contextId: contextId, new: false)
    }

    /// The Suite's list key for a draft (set by tests and demo mode as the server reads it from the shared draft).
    public var suiteToolOf: @Sendable (String) async -> String = { _ in "shot" }

    private func thread(contextKind: String, contextId: String, new: Bool) async throws -> ClaudeThread {
        guard ["camera", "edit", "recreate", "suite"].contains(contextKind) else { throw ApiError("bad_request", "contextKind") }
        // A recreate thread is on one of the owner's references (rx_…), else 404 (as the server).
        if contextKind == "recreate", !contextId.hasPrefix("rx_") { throw ApiError("not_found", "Reference not found") }
        var key = "\(contextKind):\(contextId)"
        if contextKind == "suite" { key = "suite:\(await suiteToolOf(contextId))" }
        return locked {
            if !new, let t = threads.values.filter({ $0.contextKind == contextKind && $0.contextId == contextId }).max(by: { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }) { return t }
            let brief: ClaudeBrief? = switch contextKind {
            case "recreate": ClaudeBrief(prompt: "You help the studio owner recreate a reference video's edit with MUSE's recreate tools. Price new shots first; the owner approves them in the app.",
                                         tools: ["get_recipe", "set_slot_briefs", "match_slots", "fill_slot", "open_edit", "apply_recipe", "apply_edit_ops"], referenceId: contextId)
            case "edit": ClaudeBrief(prompt: "You edit the studio owner's video in MUSE's editor.", tools: ["apply_edit_ops"], sessionId: contextId)
            case "suite": ClaudeBrief(prompt: "You fill in the studio owner's AI Suite composer with options it offers. Generating waits for the owner's approval in the app.",
                                      tools: ["suite_options", "suite_get_draft", "suite_set_draft", "suite_estimate", "suite_request_shot", "suite_feed"], assistId: contextId)
            default: nil
            }
            let t = ClaudeThread(id: nextId("ct"), contextKind: contextKind, contextId: contextId, createdAt: now(), updatedAt: now(), brief: brief, contextKey: key)
            threads[t.id] = t
            return t
        }
    }

    // MARK: Chat sessions (WS18, as the server)

    public func threads(key: String) async throws -> [ClaudeThread] {
        locked {
            threads.values.filter { $0.contextKey == key }
                .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
                .map { t in
                    var t = t
                    t.messageCount = (messages[t.id] ?? []).filter { $0.role != "tool" }.count
                    return t
                }
        }
    }

    public func newThread(contextKind: String, contextId: String) async throws -> ClaudeThread {
        let t = try await thread(contextKind: contextKind, contextId: contextId, new: true)
        emit(.thread(t))
        return t
    }

    public func renameThread(_ id: String, title: String) async throws -> ClaudeThread {
        let t: ClaudeThread = try locked {
            guard var t = threads[id] else { throw ApiError("not_found", "No such thread") }
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            t.title = name.isEmpty ? (messages[id] ?? []).first { $0.role == "user" }.flatMap { ClaudeSessions.autoTitle($0.text) } : String(name.prefix(80))
            threads[id] = t
            return t
        }
        emit(.thread(t))
        return t
    }

    public func deleteThread(_ id: String) async throws {
        try locked {
            guard threads[id] != nil else { throw ApiError("not_found", "No such thread") }
            threads[id] = nil
            messages[id] = nil
            for (k, t) in turns where t.threadId == id { turns[k] = nil }
        }
        emit(.threadDeleted(threadId: id))
    }

    /// A stored user message names a chat that has no name yet; any message moves it up its list.
    private func touch(_ threadId: String, userText: String?) -> ClaudeThread? {
        guard var t = threads[threadId] else { return nil }
        t.updatedAt = max(now(), t.updatedAt + 1)
        var named = false
        if t.title == nil, let u = userText, let title = ClaudeSessions.autoTitle(u) {
            t.title = title
            named = true
        }
        threads[threadId] = t
        return named ? t : nil
    }

    public func threadDetail(_ id: String) async throws -> ClaudeThreadDetail {
        try locked {
            guard let t = threads[id] else { throw ApiError("not_found", "No such thread") }
            return ClaudeThreadDetail(thread: t, messages: Array((messages[id] ?? []).suffix(100)),
                                      activeTurn: turns.values.first { $0.threadId == id && $0.isOpen })
        }
    }

    public func setClaudeSession(threadId: String, claudeSessionId: String) async throws -> ClaudeThread {
        try locked {
            guard var t = threads[threadId] else { throw ApiError("not_found", "No such thread") }
            t.claudeSessionId = claudeSessionId
            t.updatedAt = now()
            threads[threadId] = t
            return t
        }
    }

    public func postMessage(threadId: String, text: String) async throws -> ClaudeMessagePosted {
        let r: ClaudeMessagePosted = try locked {
            guard threads[threadId] != nil else { throw ApiError("not_found", "No such thread") }
            guard info.ready, now() - lastBeat < 45_000 else { throw ApiError("mac_offline", "Your Mac is offline") }
            if turns.values.contains(where: { $0.threadId == threadId && $0.isOpen }) { throw ApiError("claude_busy", "Claude is still answering") }
            let turn = ClaudeTurn(id: nextId("tu"), threadId: threadId, text: text, from: "phone", createdAt: now())
            let m = ClaudeMessage(id: nextId("cmsg"), threadId: threadId, role: "user", source: "phone", text: text, turnId: turn.id, createdAt: now())
            turns[turn.id] = turn
            messages[threadId, default: []].append(m)
            _ = touch(threadId, userText: text)
            return ClaudeMessagePosted(message: m, turn: turn)
        }
        emit(.message(threadId: threadId, r.message))
        emit(.turn(r.turn))
        return r
    }

    /// Tests: a phone turn as the server would queue it, without the Mac being online.
    @discardableResult
    public func queuePhoneTurn(threadId: String, text: String) -> ClaudeTurn {
        let turn = locked {
            let turn = ClaudeTurn(id: nextId("tu"), threadId: threadId, text: text, from: "phone", createdAt: now())
            turns[turn.id] = turn
            messages[threadId, default: []].append(ClaudeMessage(id: nextId("cmsg"), threadId: threadId, role: "user", source: "phone", text: text, turnId: turn.id, createdAt: now()))
            return turn
        }
        emit(.turn(turn))
        return turn
    }

    public func turn(_ id: String) -> ClaudeTurn? { locked { turns[id] } }

    public func pendingTurns() async throws -> [ClaudeTurn] {
        locked { turns.values.filter { $0.state == "queued" }.sorted { $0.createdAt < $1.createdAt } }
    }

    public func claim(turnId: String) async throws -> ClaudeTurn {
        try locked {
            claims.append(turnId)
            if let c = claimError { throw ApiError(c, c) }
            guard var t = turns[turnId] else { throw ApiError("not_found", "No such turn") }
            guard t.state == "queued" else { throw ApiError("already_claimed", "Already claimed") }
            t.state = "running"
            t.claimedAt = now()
            turns[turnId] = t
            return t
        }
    }

    public func stopTurn(_ turnId: String) async throws { emit(.stop(turnId: turnId)) }

    public func postEvents(threadId: String, _ batch: ClaudeEventBatch) async throws {
        var stored: [ClaudeMessage] = []
        var named: [ClaudeThread] = []
        try locked {
            guard threads[threadId] != nil else { throw ApiError("not_found", "No such thread") }
            let size = (try? JSONEncoder().encode(batch).count) ?? 0
            guard size <= ClaudeEventBatcher.serverLimit else { throw ApiError("too_large", "Too large") }
            posted.append((threadId, batch))
            let source = batch.turnId == nil ? "mac" : "mac"
            for e in batch.events {
                var m: ClaudeMessage?
                switch e {
                case .user(let text, let ids):
                    m = ClaudeMessage(id: nextId("cmsg"), threadId: threadId, role: "user", source: source, text: text, turnId: batch.turnId, createdAt: now())
                    if !ids.isEmpty { m?.attachments = ids.map { ClaudeAttachment(uploadId: $0, url: "/uploads/\($0).jpg") } }
                case .assistant(let text): m = ClaudeMessage(id: nextId("cmsg"), threadId: threadId, role: "assistant", source: source, text: text, turnId: batch.turnId, createdAt: now())
                case .tool(let id, let name, let status, let summary, _):
                    guard status != .running else { break }
                    m = ClaudeMessage(id: nextId("cmsg"), threadId: threadId, role: "tool", source: source, turnId: batch.turnId,
                                      tool: ClaudeToolRef(id: id, name: name, ok: status == .done, summary: summary), createdAt: now())
                case .image: m = ClaudeMessage(id: nextId("cmsg"), threadId: threadId, role: "tool", source: source, turnId: batch.turnId,
                                               image: ClaudeImageRef(url: "/uploads/claude/\(threadId)/\(counter).png"), createdAt: now())
                case .done(let ok, let error, _):
                    if let t = batch.turnId, var turn = turns[t] {
                        turn.state = ok ? "done" : error == "Stopped" ? "stopped" : "failed"
                        turn.error = error
                        turn.finishedAt = now()
                        turns[t] = turn
                    }
                case .text: break
                }
                if let m {
                    messages[threadId, default: []].append(m)
                    stored.append(m)
                    if let t = touch(threadId, userText: m.role == "user" ? m.text : nil) { named.append(t) }
                }
            }
        }
        for t in named { emit(.thread(t)) }
        for e in batch.events { emit(.event(threadId: threadId, turnId: batch.turnId, e)) }
        for m in stored { emit(.message(threadId: threadId, m)) }
    }

    /// Step 6b: the demo's model list (the server's, in short), so the panel shows its model line in demo mode too.
    public func claudeModels() async throws -> ClaudeModelList {
        ClaudeModelList(models: [
            ClaudeModelInfo(id: "claude-opus-5-5", name: "Claude Opus 5.5", speed: "Steady", cost: "Standard cost", good: "Most work"),
            ClaudeModelInfo(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", speed: "Fast", cost: "About half of Opus", good: "Everyday questions"),
            ClaudeModelInfo(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", speed: "Fastest", cost: "Lowest cost", good: "Short answers"),
        ], default: nil, studioDefault: "claude-opus-5-5")
    }
    public func setChatModel(_ id: String, model: String?) async throws {}
    public func setDefaultModel(_ model: String?) async throws {}

    public func apiTurn(threadId: String, text: String) -> AsyncThrowingStream<ChatEvent, Error> {
        let on = locked { fallback.usable }
        return AsyncThrowingStream { cont in
            guard on else {
                cont.finish(throwing: ApiError("fallback_off", "The studio API key fallback is off"))
                return
            }
            cont.yield(.text("On the studio API key: "))
            cont.yield(.text(text))
            cont.yield(.done(stopReason: "end_turn", usage: nil))
            cont.finish()
        }
    }

    public func mcpSessionToken(ttlMinutes: Int?) async throws -> McpSessionToken {
        locked {
            tokensMinted += 1
            return McpSessionToken(token: "muse_oat_fake\(tokensMinted)", expiresAt: now() + Double(ttlMinutes ?? 240) * 60_000, mcpUrl: "\(base)/mcp")
        }
    }

    public func events() -> AsyncStream<ClaudeLiveEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont in
            let id = UUID()
            locked { listeners[id] = cont }
            cont.yield(.connected)
            cont.onTermination = { [weak self] _ in self?.locked { _ = self?.listeners.removeValue(forKey: id) } }
        }
    }
}

/// A launcher that replays stream-json lines instead of starting Claude Code: demo mode, previews and tests.
public final class ClaudeScriptedLauncher: ClaudeLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private let script: @Sendable (String) -> [String]
    public let delay: Double
    public private(set) var launches: [(arguments: [String], cwd: URL, stdin: String, config: String?)] = []

    /// `script` gets the user's text and returns the lines to print.
    public init(delay: Double = 0, script: @escaping @Sendable (String) -> [String] = { ClaudeDemoScript.lines($0) }) {
        self.delay = delay
        self.script = script
    }

    public func launch(executable: String, arguments: [String], cwd: URL, environment: [String: String], stdin: String,
                       onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32, String) -> Void) throws -> any ClaudeProcessHandle {
        var config: String?
        if let i = arguments.firstIndex(of: "--mcp-config"), i + 1 < arguments.count { config = try? String(contentsOfFile: arguments[i + 1], encoding: .utf8) }
        lock.lock()
        launches.append((arguments, cwd, stdin, config))
        lock.unlock()
        let text: String = {
            guard let d = stdin.data(using: .utf8), case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: d),
                  case .object(let m)? = o["message"] else { return "" }
            return m.jStr("content") ?? ""
        }()
        let lines = script(text)
        let h = Handle()
        let delay = self.delay
        Task.detached {
            for l in lines {
                if h.interrupted { break }
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                if h.interrupted { break }
                onLine(l)
            }
            h.finish()
            onExit(h.interrupted ? 130 : 0, "")
        }
        return h
    }

    final class Handle: ClaudeProcessHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var stop = false
        private var done = false
        var interrupted: Bool { lock.lock(); defer { lock.unlock() }; return stop }
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !done }
        func finish() { lock.lock(); done = true; lock.unlock() }
        func interrupt() { lock.lock(); stop = true; lock.unlock() }
        func terminate() { interrupt() }
    }
}

/// The demo turn: a little streamed text, one edit chip and a short answer (no real Claude anywhere).
public enum ClaudeDemoScript {
    public static func lines(_ text: String) -> [String] {
        let sid = "demo-session-1"
        func j(_ v: JSONValue) -> String {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: (try? e.encode(v)) ?? Data(), as: UTF8.self)
        }
        func delta(_ s: String) -> String {
            j(.object(["type": .string("stream_event"), "session_id": .string(sid),
                       "event": .object(["type": .string("content_block_delta"), "index": .number(0), "delta": .object(["type": .string("text_delta"), "text": .string(s)])])]))
        }
        let intro = "On it. I'll look at the edit first."
        let outro = "Done: I trimmed 0:03–0:05 so the turn lands on the beat. Undo brings it back."
        return [
            j(.object(["type": .string("system"), "subtype": .string("init"), "session_id": .string(sid), "model": .string("claude-sonnet-demo"),
                       "tools": .array([.string("mcp__muse__get_edit"), .string("mcp__muse__apply_edit_ops")]),
                       "mcp_servers": .array([.object(["name": .string("muse"), "status": .string("connected")])])])),
            delta("On it. "), delta("I'll look at the edit first."),
            j(.object(["type": .string("assistant"), "session_id": .string(sid), "message": .object(["id": .string("msg_demo1"), "role": .string("assistant"),
                       "content": .array([.object(["type": .string("text"), "text": .string(intro)])])])])),
            j(.object(["type": .string("assistant"), "session_id": .string(sid), "message": .object(["id": .string("msg_demo1"), "role": .string("assistant"),
                       "content": .array([.object(["type": .string("tool_use"), "id": .string("toolu_demo1"), "name": .string("mcp__muse__apply_edit_ops"),
                                                   "input": .object(["ops": .array([.object(["op": .string("trim"), "inSec": .number(3), "outSec": .number(5)])])])])])])])),
            j(.object(["type": .string("user"), "session_id": .string(sid), "message": .object(["role": .string("user"),
                       "content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("toolu_demo1"), "content": .string("{\"revision\":2}")])])])])),
            delta("Done: "), delta("I trimmed 0:03–0:05 so the turn lands on the beat. Undo brings it back."),
            j(.object(["type": .string("assistant"), "session_id": .string(sid), "message": .object(["id": .string("msg_demo2"), "role": .string("assistant"),
                       "content": .array([.object(["type": .string("text"), "text": .string(outro)])])])])),
            j(.object(["type": .string("result"), "subtype": .string("success"), "is_error": .bool(false), "result": .string(outro), "session_id": .string(sid),
                       "total_cost_usd": .number(0)])),
        ]
    }
}
