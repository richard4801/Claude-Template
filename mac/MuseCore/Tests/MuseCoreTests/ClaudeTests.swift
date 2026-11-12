import Foundation
import XCTest
@testable import MuseCore

/// Claude on the owner's plan (plans/api.md "Claude on the owner's plan"; plans/claude-editing.md C–E): the stream-json parser
/// on a recorded transcript, chip text, the exact command line, the transcript reducer, batching, the models and live events.
final class ClaudeTests: XCTestCase {
    static func fixtureLines() throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "claude-stream", withExtension: "jsonl", subdirectory: "Fixtures/claude"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: Parser

    func testParserReadsTheRecordedTranscript() throws {
        let events = try Self.fixtureLines().flatMap(ClaudeStreamParser.parse)
        guard case .initialized(let sid, let model, let tools, let servers)? = events.first else { return XCTFail("no init") }
        XCTAssertEqual(sid, "5f1c2a9e-7d1b-4c1e-9a55-3c2f9b8e1d01")
        XCTAssertEqual(model, "claude-sonnet-4-5-20250929")
        XCTAssertTrue(tools.contains("mcp__muse__apply_edit_ops"))
        XCTAssertEqual(servers, [.init(name: "muse", status: "connected")])

        let deltas = events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }
        XCTAssertEqual(deltas, ["Let me look ", "at the edit.", "Trimmed 0:03–0:05; ", "the draft is $1.92."])
        let texts = events.compactMap { if case .assistantText(_, let t) = $0 { return t }; return nil }
        XCTAssertEqual(texts, ["Let me look at the edit.", "Trimmed 0:03–0:05; the draft is $1.92."])
        let uses = events.compactMap { if case .toolUse(let id, let name, _) = $0 { return "\(id) \(name)" }; return nil }
        XCTAssertEqual(uses, ["toolu_01 mcp__muse__apply_edit_ops", "toolu_02 mcp__muse__get_frame", "toolu_03 mcp__muse__create_shot_draft", "toolu_04 mcp__muse__set_camera_path"])
        let results = events.compactMap { e -> (String, Bool, Int)? in if case .toolResult(let id, let err, _, let imgs) = e { return (id, err, imgs.count) }; return nil }
        XCTAssertEqual(results.map(\.0), ["toolu_01", "toolu_02", "toolu_03", "toolu_04"])
        XCTAssertEqual(results.map(\.1), [false, false, false, true])
        XCTAssertEqual(results.map(\.2), [0, 1, 0, 0])
        guard case .result(let ok, let subtype, _, let rsid, let cost)? = events.last(where: { $0 != .ignored }) else { return XCTFail("no result") }
        XCTAssertTrue(ok)
        XCTAssertEqual(subtype, "success")
        XCTAssertEqual(rsid, sid)
        XCTAssertEqual(cost ?? 0, 0.0421, accuracy: 1e-9)
    }

    func testParserIgnoresJunkAndUnknownLines() {
        for line in ["", "not json", "[1,2]", "{\"type\":\"rate_limit_event\"}", "{\"type\":\"system\",\"subtype\":\"compact_boundary\"}",
                     "{\"type\":\"assistant\"}", "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"…\"}]}}",
                     "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\"}}}",
                     "{\"type\":\"user\",\"message\":{\"content\":\"plain text\"}}", "{\"type\":42}"] {
            XCTAssertEqual(ClaudeStreamParser.parse(line), [.ignored], line)
        }
        // Errors and extra fields.
        XCTAssertEqual(ClaudeStreamParser.parse("{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"new_field\":{}}"),
                       [.result(ok: false, subtype: "error_max_turns", text: nil, sessionId: nil, costUsd: nil)])
        // MCP-shaped image content is read too.
        let mcp = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":[{\"type\":\"image\",\"data\":\"AAAA\",\"mimeType\":\"image/jpeg\"}]}]}}"
        XCTAssertEqual(ClaudeStreamParser.parse(mcp), [.toolResult(toolUseId: "t1", isError: false, text: "", images: [.init(data: "AAAA", mimeType: "image/jpeg")])])
    }

    func testMapperTurnsTheTranscriptIntoContractEvents() throws {
        var m = ClaudeEventMapper()
        let events = try Self.fixtureLines().flatMap(ClaudeStreamParser.parse).flatMap { m.map($0) }
        XCTAssertEqual(m.sessionId, "5f1c2a9e-7d1b-4c1e-9a55-3c2f9b8e1d01")
        let tools = events.compactMap { e -> String? in
            if case .tool(let id, let name, let status, let summary, _) = e { return "\(id) \(name) \(status.rawValue) \(summary ?? "-")" }
            return nil
        }
        XCTAssertEqual(tools, [
            "toolu_01 apply_edit_ops running Trimmed 0:03–0:05",
            "toolu_01 apply_edit_ops done Trimmed to 0:03.0–0:05.0", // the tool's own label wins
            "toolu_02 get_frame running Grabbed frame · 0:04",
            "toolu_02 get_frame done Grabbed frame · 0:04",
            "toolu_03 create_shot_draft running Shot draft",
            "toolu_03 create_shot_draft done Shot draft · $1.92",
            "toolu_04 set_camera_path running Saved camera path",
            "toolu_04 set_camera_path error Saved camera path · failed",
        ])
        let images = events.compactMap { if case .image(let d, let mt) = $0 { return "\(mt) \(d.prefix(8))" }; return nil }
        XCTAssertEqual(images, ["image/png iVBORw0K"])
        XCTAssertEqual(events.last, .done(ok: true, error: nil, model: "claude-sonnet-4-5-20250929"))
        XCTAssertEqual(events.filter { if case .text = $0 { return true }; return false }.count, 4)
    }

    func testMapperFinishesAStoppedOrCrashedRun() {
        var m = ClaudeEventMapper()
        XCTAssertEqual(m.finishWithoutResult(stopped: true, exitCode: 130, stderr: ""), .done(ok: false, error: "Stopped", model: nil))
        var n = ClaudeEventMapper()
        XCTAssertEqual(n.finishWithoutResult(stopped: false, exitCode: 1, stderr: "warn\nError: Invalid MCP configuration\n"),
                       .done(ok: false, error: "Claude Code stopped: Error: Invalid MCP configuration", model: nil))
        // An oversized image is not mirrored (the server takes ≤ 2 MB).
        var o = ClaudeEventMapper()
        let big = String(repeating: "A", count: 3 * 1024 * 1024)
        let out = o.map(.toolResult(toolUseId: "x", isError: false, text: "", images: [.init(data: big, mimeType: "image/png")]))
        XCTAssertEqual(out.count, 1)
    }

    // MARK: Chips

    func testChipText() {
        func s(_ tool: String, _ input: JSONValue? = nil, _ result: String? = nil, err: Bool = false) -> String {
            ClaudeChipText.summary(tool: tool, input: input, result: result, isError: err)
        }
        let trim: JSONValue = .object(["ops": .array([.object(["op": .string("trim"), "inSec": .number(3.2), "outSec": .number(5)])])])
        XCTAssertEqual(s("mcp__muse__apply_edit_ops", trim), "Trimmed 0:03–0:05")
        let look: JSONValue = .object(["ops": .array([.object(["op": .string("look"), "name": .string("golden_warmth")]), .object(["op": .string("adjust")])])])
        XCTAssertEqual(s("mcp__muse__apply_edit_ops", look), "Applied Look · Golden warmth + 1 more")
        XCTAssertEqual(s("mcp__muse__apply_edit_ops", .object(["ops": .array([.object(["type": .string("speed"), "speed": .number(2)])])])), "Speed 2×")
        XCTAssertEqual(s("mcp__muse__set_camera_path"), "Saved camera path")
        XCTAssertEqual(s("mcp__muse__create_shot_draft", nil, "{\"estimate\":{\"usd\":1.92}}"), "Shot draft · $1.92")
        XCTAssertEqual(s("mcp__muse__get_frame", .object(["t": .number(75)])), "Grabbed frame · 1:15")
        XCTAssertEqual(s("mcp__muse__undo_edit"), "Undid the last change")
        XCTAssertEqual(s("mcp__muse__export_video", .object(["preset": .string("reels_1080")])), "Export · Reels 1080")
        XCTAssertEqual(s("mcp__muse__detect_scene_cuts"), "Detect scene cuts")
        XCTAssertEqual(s("mcp__blender__get_scene_info"), "Blender · get scene info")
        XCTAssertEqual(s("mcp__muse__cut_silences", nil, "boom", err: true), "Cut silences · failed")
        // A result label wins (workstream 3's editing tools), also from a multi-part result.
        XCTAssertEqual(s("mcp__muse__apply_edit_ops", trim, "{\"label\":\"Look · film-gold 70 %\"}"), "Look · film-gold 70 %")
        XCTAssertEqual(s("mcp__muse__get_frame", nil, "frame\n{\"label\":\"Looked at 0:04.2 (approximate)\"}"), "Looked at 0:04.2 (approximate)")
        XCTAssertEqual(ClaudeChipText.shortName("mcp__other__do_it"), "do_it")
        XCTAssertEqual(ClaudeChipText.time(3.4), "0:03")
    }

    // MARK: Command

    /// Step 6b: a chat's model goes to Claude Code as --model; anything that isn't a plain model id is left out.
    func testCommandPassesOnlyAPlainModelId() {
        var c = ClaudeCommand(mcpURL: "https://muse.test/mcp", token: "t")
        c.model = "claude-sonnet-5-5"
        XCTAssertEqual(Array(c.arguments(configPath: "/x").suffix(2)), ["--model", "claude-sonnet-5-5"])
        c.model = "opus --dangerously-skip-permissions"
        XCTAssertFalse(c.arguments(configPath: "/x").contains("--model"))
        c.model = nil
        XCTAssertFalse(c.arguments(configPath: "/x").contains("--model"))
    }

    func testCommandArgumentsAreExact() {
        let c = ClaudeCommand(mcpURL: "https://muse.test/mcp", token: "muse_oat_x")
        XCTAssertEqual(c.arguments(configPath: "/u/MUSE/Claude/ct_1/.mcp.json"), [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--mcp-config", "/u/MUSE/Claude/ct_1/.mcp.json", "--strict-mcp-config",
            "--allowedTools", "mcp__muse",
            "--disallowedTools", "Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch",
            "--permission-mode", "dontAsk", "--setting-sources", "user",
        ])
        let b = ClaudeCommand(mcpURL: "https://muse.test/mcp", token: "t", blender: .init(uvx: "/opt/homebrew/bin/uvx"), resume: "sess-1")
        let a = b.arguments(configPath: "/c.json")
        XCTAssertEqual(Array(a[10...13]), ["--allowedTools", "mcp__muse", "mcp__blender", "--disallowedTools"])
        XCTAssertEqual(Array(a.suffix(2)), ["--resume", "sess-1"])
        XCTAssertFalse(a.contains("--model"))
    }

    func testMcpConfigAndStdin() {
        let c = ClaudeCommand(mcpURL: "https://muse.test/mcp", token: "muse_oat_x")
        XCTAssertEqual(String(decoding: c.mcpConfigJSON(), as: UTF8.self),
                       #"{"mcpServers":{"muse":{"headers":{"Authorization":"Bearer muse_oat_x"},"type":"http","url":"https://muse.test/mcp"}}}"#)
        let b = ClaudeCommand(mcpURL: "u", token: "t", blender: .init(uvx: "/bin/uvx"))
        XCTAssertTrue(String(decoding: b.mcpConfigJSON(), as: UTF8.self).contains(#""blender":{"args":["mcp-for-blender"],"command":"/bin/uvx""#))
        XCTAssertEqual(ClaudeCommand.stdinLine("Trim \"the\" start\nplease"),
                       #"{"message":{"content":"Trim \"the\" start\nplease","role":"user"},"parent_tool_use_id":null,"type":"user"}"# + "\n")
        let env = ClaudeCommand.environment(["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk", "CLAUDECODE": "1", "LANG": "en"], executable: "/Users/o/.local/bin/claude", home: "/Users/o")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertEqual(env["LANG"], "en")
        XCTAssertTrue(env["PATH"]!.hasPrefix("/usr/bin:/Users/o/.local/bin:/opt/homebrew/bin"))
        // Claude Code's 30 s MCP start timeout is too short for uvx's first fetch of mcp-for-blender.
        XCTAssertEqual(env["MCP_TIMEOUT"], "120000")
        XCTAssertEqual(ClaudeCommand.environment(["MCP_TIMEOUT": "300000"], executable: "/c", home: "/h")["MCP_TIMEOUT"], "300000")
        let bj = String(decoding: b.mcpConfigJSON(), as: UTF8.self)
        XCTAssertTrue(bj.contains(#""env":{"BLENDER_MCP_SAFE_MODE":"1","DISABLE_TELEMETRY":"true"}"#))
    }

    func testLocatorParsing() {
        XCTAssertEqual(ClaudeCodeLocator.version("2.1.211 (Claude Code)\n"), "2.1.211")
        XCTAssertNil(ClaudeCodeLocator.version("command not found"))
        XCTAssertTrue(ClaudeCodeLocator.auth(exitCode: 0, output: #"{"loggedIn":true,"authMethod":"claude.ai"}"#).signedIn)
        XCTAssertEqual(ClaudeCodeLocator.auth(exitCode: 0, output: #"{"loggedIn":true,"authMethod":"claude.ai"}"#).method, "claude.ai")
        XCTAssertFalse(ClaudeCodeLocator.auth(exitCode: 1, output: #"{"loggedIn":false}"#).signedIn)
        XCTAssertFalse(ClaudeCodeLocator.auth(exitCode: 1, output: "garbage").signedIn)
        let c = ClaudeCodeLocator.candidates(home: "/Users/o", path: "/usr/bin:/opt/homebrew/bin")
        XCTAssertEqual(c, ["/usr/bin/claude", "/opt/homebrew/bin/claude", "/Users/o/.local/bin/claude", "/usr/local/bin/claude", "/Users/o/.claude/local/claude"])
        XCTAssertTrue(ClaudeCodeLocator.installScript().contains("curl -fsSL https://claude.ai/install.sh | bash"))
        XCTAssertTrue(ClaudeCodeLocator.signInScript(executable: "/x/claude").contains("\"/x/claude\" auth login"))
    }

    // MARK: Transcript

    func testTranscriptStreamsThenDedupsAgainstStoredMessages() throws {
        var t = ClaudeTranscript()
        var m = ClaudeEventMapper()
        t.apply(.user(text: "Trim the start"))
        for e in try Self.fixtureLines().flatMap(ClaudeStreamParser.parse).flatMap({ m.map($0) }) { t.apply(e) }
        XCTAssertFalse(t.streaming)
        XCTAssertEqual(t.model, "claude-sonnet-4-5-20250929")
        let kinds = t.items.map { item -> String in
            switch item {
            case .user(_, let text, _): return "user:\(text)"
            case .assistant(_, let text, let s): return "assistant:\(text)\(s ? "…" : "")"
            case .tool(_, let name, let summary, let st): return "tool:\(name):\(summary):\(st.rawValue)"
            case .image(_, let url): return "image:\(url.prefix(21))"
            case .card(_, _, let c): return "card:\(c.kind)"
            }
        }
        XCTAssertEqual(kinds, [
            "user:Trim the start", "assistant:Let me look at the edit.",
            "tool:apply_edit_ops:Trimmed to 0:03.0–0:05.0:done", "tool:get_frame:Grabbed frame · 0:04:done", "image:data:image/png;base64",
            "tool:create_shot_draft:Shot draft · $1.92:done", "tool:set_camera_path:Saved camera path · failed:error",
            "assistant:Trimmed 0:03–0:05; the draft is $1.92.",
        ])
        // The server's stored copies arrive: nothing shows twice.
        let msgs = [
            ClaudeMessage(id: "m1", threadId: "ct", role: "user", source: "mac", text: "Trim the start", createdAt: 1),
            ClaudeMessage(id: "m2", threadId: "ct", role: "assistant", source: "mac", text: "Let me look at the edit.", createdAt: 2),
            ClaudeMessage(id: "m3", threadId: "ct", role: "tool", source: "mac", tool: ClaudeToolRef(id: "toolu_01", name: "apply_edit_ops", ok: true, summary: "Trimmed to 0:03.0–0:05.0"), createdAt: 3),
            ClaudeMessage(id: "m4", threadId: "ct", role: "tool", source: "mac", tool: ClaudeToolRef(id: "toolu_02", name: "get_frame", ok: true, summary: "Grabbed frame · 0:04"), createdAt: 4),
            ClaudeMessage(id: "m5", threadId: "ct", role: "tool", source: "mac", image: ClaudeImageRef(url: "/uploads/f.png"), createdAt: 5),
        ]
        for msg in msgs { t.upsert(msg) }
        t.upsert(msgs[2]) // the same id again
        XCTAssertEqual(t.items.count, 8)
        XCTAssertEqual(t.live.count, 3)
        XCTAssertEqual(t.items.map(\.id).prefix(5), ["m1", "m2", "toolu_01", "toolu_02", "m5"])
        // A full reload after the turn replaces the live rows.
        t.load(msgs)
        XCTAssertEqual(t.items.count, 5)
        XCTAssertTrue(t.live.isEmpty)
    }

    func testTranscriptToolStoredWhileRunningTakesLiveState() {
        var t = ClaudeTranscript()
        t.apply(.tool(id: "a", name: "denoise", status: .running, summary: "Cleaned up the audio", input: nil))
        t.upsert(ClaudeMessage(id: "m", threadId: "ct", role: "tool", source: "mac", tool: ClaudeToolRef(id: "a", name: "denoise", summary: "Cleaned up the audio"), createdAt: 1))
        t.apply(.tool(id: "a", name: "denoise", status: .error, summary: "Cleaned up the audio · failed", input: nil))
        XCTAssertEqual(t.items, [.tool(id: "a", name: "denoise", summary: "Cleaned up the audio · failed", status: .error)])
        t.apply(.text(delta: "Sorr"))
        t.apply(.done(ok: false, error: "Stopped", model: nil))
        XCTAssertEqual(t.lastError, "Stopped")
        XCTAssertEqual(t.items.last, .assistant(id: t.items.last!.id, text: "Sorr", streaming: false))
    }

    // MARK: Batching and tokens

    func testBatcherMergesDeltasAndSplitsBySize() {
        var b = ClaudeEventBatcher(maxBytes: 3000)
        b.add(.text(delta: "a"))
        b.add(.text(delta: "b"))
        b.add(.tool(id: "t", name: "x", status: .running, summary: nil, input: nil))
        b.add(.text(delta: "c"))
        let one = b.drain(turnId: "tu_1")
        XCTAssertEqual(one, [ClaudeEventBatch(turnId: "tu_1", events: [.text(delta: "ab"), .tool(id: "t", name: "x", status: .running, summary: nil, input: nil), .text(delta: "c")])])
        XCTAssertTrue(b.isEmpty)
        let img = String(repeating: "A", count: 2000)
        b.add(.image(data: img, mimeType: "image/png"))
        b.add(.image(data: img, mimeType: "image/png"))
        b.add(.done(ok: true, error: nil, model: nil))
        let two = b.drain(turnId: nil)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.map(\.events.count), [1, 2])
        for batch in two { XCTAssertLessThanOrEqual(try JSONEncoder().encode(batch).count, 3000) }
        XCTAssertEqual(ClaudeEventBatcher().maxBytes, 4 * 1024 * 1024 - 64 * 1024)
    }

    func testTokenCacheKeepsTokenUntilFiveMinutesBeforeExpiry() async throws {
        let clock = Clock()
        let api = FakeClaudeAPI(now: { clock.now })
        let cache = ClaudeTokenCache(now: { clock.now })
        let a = try await cache.token(api)
        clock.now += 230 * 60_000 // 10 min left
        let b = try await cache.token(api)
        XCTAssertEqual(a, b)
        clock.now += 6 * 60_000 // 4 min left
        let c = try await cache.token(api)
        XCTAssertNotEqual(a.token, c.token)
        XCTAssertEqual(api.tokensMinted, 2)
    }

    final class Clock: @unchecked Sendable { var now: Double = 1_000_000 }

    // MARK: Models and live events

    func testContractJSONDecodes() throws {
        let status = #"{"mac":{"online":true,"claudeCode":{"installed":true,"signedIn":true,"version":"2.1.211","model":"claude-sonnet"},"answeringTurn":"tu_1"},"apiFallback":{"available":true,"enabled":false},"connectorUrl":"https://m.test/mcp","openInClaudeUrl":"https://claude.ai/new"}"#
        let s = try JSONDecoder().decode(ClaudeStatus.self, from: Data(status.utf8))
        XCTAssertTrue(s.mac.claudeCode.ready)
        XCTAssertEqual(s.mac.answeringTurn, "tu_1")
        XCTAssertFalse(s.apiFallback.usable)
        XCTAssertEqual(s.connectorUrl, "https://m.test/mcp")
        let detail = #"{"id":"ct_1","contextKind":"edit","contextId":"es_1","claudeSessionId":"s1","createdAt":1,"updatedAt":2,"messages":[{"id":"m1","threadId":"ct_1","role":"tool","source":"phone","text":"","tool":{"id":"t","name":"get_frame","ok":true},"createdAt":3},{"broken":true}],"activeTurn":{"id":"tu_1","threadId":"ct_1","text":"hi","from":"phone","state":"running","createdAt":4}}"#
        let d = try JSONDecoder().decode(ClaudeThreadDetail.self, from: Data(detail.utf8))
        XCTAssertEqual(d.thread.claudeSessionId, "s1")
        XCTAssertEqual(d.messages.count, 1)
        XCTAssertEqual(d.activeTurn?.state, "running")
        let tok = try JSONDecoder().decode(McpSessionToken.self, from: Data(#"{"token":"muse_oat_1","expiresAt":"2026-11-06T12:00:00Z","mcpUrl":"https://m/mcp"}"#.utf8))
        XCTAssertEqual(tok.expiresAt, 1_793_966_400_000)
        // Events round-trip with the contract's field names.
        let ev = ClaudeEvent.tool(id: "t", name: "trim", status: .done, summary: "Trimmed", input: nil)
        XCTAssertEqual(String(decoding: try { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return try e.encode(ev) }(), as: UTF8.self),
                       #"{"id":"t","name":"trim","status":"done","summary":"Trimmed","type":"tool"}"#)
        XCTAssertEqual(try JSONDecoder().decode(ClaudeEvent.self, from: Data(#"{"type":"done","ok":false,"error":"x"}"#.utf8)), .done(ok: false, error: "x", model: nil))
    }

    func testLiveEventFilter() {
        var f = ClaudeLiveEventFilter()
        func feed(_ json: String) -> ClaudeLiveEvent? {
            _ = f.feed("data: \(json)")
            return f.feed("")
        }
        XCTAssertEqual(feed(#"{"type":"claude","op":"turn","turn":{"id":"tu_1","threadId":"ct_1","text":"hi","from":"phone","state":"queued","createdAt":1}}"#),
                       .turn(ClaudeTurn(id: "tu_1", threadId: "ct_1", text: "hi", createdAt: 1)))
        XCTAssertEqual(feed(#"{"type":"claude","op":"stop","turnId":"tu_1"}"#), .stop(turnId: "tu_1"))
        XCTAssertEqual(feed(#"{"type":"claude","op":"event","threadId":"ct_1","turnId":"tu_1","event":{"type":"text","delta":"Hi"}}"#),
                       .event(threadId: "ct_1", turnId: "tu_1", .text(delta: "Hi")))
        XCTAssertNil(feed(#"{"type":"claude","op":"event","threadId":"ct_1","event":{"type":"future"}}"#))
        XCTAssertNil(feed(#"{"type":"blender","op":"call"}"#))
        XCTAssertNil(feed(#"{"type":"claude","op":"later"}"#))
        if case .message(let tid, let m)? = feed(#"{"type":"claude","op":"message","threadId":"ct_1","message":{"id":"m1","threadId":"ct_1","role":"user","source":"phone","text":"yo","createdAt":5}}"#) {
            XCTAssertEqual(tid, "ct_1")
            XCTAssertEqual(m.text, "yo")
        } else { XCTFail("message") }
    }

    // MARK: Queue

    func testQueueRunsOneTurnPerThread() {
        var q = ClaudeTurnQueue()
        XCTAssertTrue(q.enqueue(ClaudeJob(id: "l1", threadId: "a", text: "1")))
        XCTAssertTrue(q.enqueue(ClaudeJob(id: "tu_1", threadId: "a", text: "2", turnId: "tu_1")))
        XCTAssertFalse(q.enqueue(ClaudeJob(id: "tu_1", threadId: "a", text: "2", turnId: "tu_1")), "seen by live event and heartbeat")
        XCTAssertTrue(q.enqueue(ClaudeJob(id: "l2", threadId: "b", text: "3")))
        XCTAssertEqual(q.threadsWithWork, ["a", "b"])
        XCTAssertEqual(q.next("a")?.id, "l1")
        XCTAssertNil(q.next("a"), "a is busy")
        XCTAssertEqual(q.queuedCount("a"), 1)
        XCTAssertEqual(q.threadsWithWork, ["b"])
        XCTAssertTrue(q.drop(turnId: "tu_1"))
        q.finish("a")
        XCTAssertNil(q.next("a"))
        XCTAssertEqual(q.next("b")?.id, "l2")
        XCTAssertEqual(q.runningThread(turnId: "nope"), nil)
    }

    // MARK: Videos (plans/claude-video-vision.md)

    func testAttachedVideoIsWatchedNotRead() throws {
        let files = [ClaudeAttachmentFile(path: "/c/MUSE/claude/ct_1/ca_1.png", uploadId: "up_1"),
                     ClaudeAttachmentFile.video(uploadId: "up_v", name: "walk.mov", seconds: 12.2)]
        let text = ClaudeAttachmentPrompt.text("Judge the walk", files)
        XCTAssertTrue(text.contains("Attached video: uploadId up_v (walk.mov, 0:12). Call watch {id: \"up_v\"} first to see it."))
        XCTAssertTrue(text.contains("Attached images (Read each one):\n- /c/MUSE/claude/ct_1/ca_1.png (uploadId up_1)"))
        XCTAssertFalse(text.contains("- (uploadId up_v)"), "a video is never in the Read list")
        XCTAssertEqual(text.components(separatedBy: "\n- ").count, 2, "one image to Read")
        XCTAssertEqual(ChatLeakFilter.userText(text), "Judge the walk")
        // A video alone: no image header.
        let only = ClaudeAttachmentPrompt.text("Look", [.video(uploadId: "up_v")])
        XCTAssertEqual(only, "Look\n\nAttached video: uploadId up_v. Call watch {id: \"up_v\"} first to see it.")
        XCTAssertEqual(ChatLeakFilter.userText(only), "Look")
        XCTAssertEqual(ClaudeAttachmentPrompt.length(185), "3:05")
        // A stored video attachment: marked, its link kept apart (a bubble never loads it as an image).
        let a = try JSONDecoder().decode(ClaudeAttachment.self, from: Data(#"{"id":"att_1","uploadId":"up_v","mimeType":"video/mp4","video":true,"url":"https://s3/v.mp4"}"#.utf8))
        XCTAssertTrue(a.isVideo)
        XCTAssertNil(a.url)
        XCTAssertEqual(a.videoURL, "https://s3/v.mp4")
    }
}
