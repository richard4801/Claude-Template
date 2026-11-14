import Foundation
import XCTest
@testable import MuseCore

/// Auto-compact (owner, 2026-11-14): the chat that died with "Prompt is too long · automatic compaction failed" carries on.
/// Detection, the 75% threshold, the handoff (no lyric lines survive), recovery in a fresh session, no loop, and the
/// preventive `/compact` before the next message. Scripted Claude Code only; nothing real is called.
final class ClaudeAutoCompactTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-compact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ClaudeEvent] = []
        func add(_ e: ClaudeEvent) { lock.lock(); items.append(e); lock.unlock() }
        var all: [ClaudeEvent] { lock.lock(); defer { lock.unlock() }; return items }
        var dones: [ClaudeEvent] { all.filter { if case .done = $0 { return true }; return false } }
    }

    private func waitFor(_ timeout: Double = 10, _ cond: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out")
    }

    private static func content(_ stdin: String) -> String {
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data(stdin.utf8)), case .object(let m)? = o["message"] else { return "" }
        return m.jStr("content") ?? ""
    }

    // MARK: Detection

    func testDetectsTheOwnersErrorAndNothingElse() {
        XCTAssertTrue(ClaudeAutoCompact.isContextOverflow(ClaudeDemoScript.overflowError))
        XCTAssertTrue(ClaudeAutoCompact.isContextOverflow("Prompt is too long"))
        XCTAssertTrue(ClaudeAutoCompact.isContextOverflow("Error: automatic compaction failed"))
        XCTAssertTrue(ClaudeAutoCompact.isContextOverflow("input length and max_tokens exceed context limit: 199000 + 21333 > 200000"))
        XCTAssertFalse(ClaudeAutoCompact.isContextOverflow(nil))
        XCTAssertFalse(ClaudeAutoCompact.isContextOverflow(""))
        XCTAssertFalse(ClaudeAutoCompact.isContextOverflow("Claude hit its step limit for this turn"))
        XCTAssertFalse(ClaudeAutoCompact.isContextOverflow("API Error: Output blocked by content filtering policy"))
        XCTAssertFalse(ClaudeAutoCompact.isContextOverflow("Stopped"))
    }

    // MARK: Threshold

    func testThresholdIsSeventyFivePercentOfTheWindow() {
        XCTAssertTrue(ClaudeAutoCompact.shouldCompact(ClaudeContextUsage(tokens: 150_000, window: 200_000), resuming: true))
        XCTAssertFalse(ClaudeAutoCompact.shouldCompact(ClaudeContextUsage(tokens: 149_000, window: 200_000), resuming: true))
        XCTAssertFalse(ClaudeAutoCompact.shouldCompact(ClaudeContextUsage(tokens: 190_000, window: 200_000), resuming: false), "a fresh chat has nothing to compact")
        XCTAssertFalse(ClaudeAutoCompact.shouldCompact(nil, resuming: true))
        XCTAssertFalse(ClaudeAutoCompact.shouldCompact(ClaudeContextUsage(tokens: 300_000, window: 1_000_000), resuming: true))
        XCTAssertTrue(ClaudeAutoCompact.shouldCompact(ClaudeContextUsage(tokens: 760_000, window: 1_000_000), resuming: true))
        // No window reported: by the model's name, 200k unless it is a 1M variant.
        XCTAssertTrue(ClaudeAutoCompact.shouldCompact(ClaudeContextUsage(tokens: 160_000, model: "claude-opus-5-5"), resuming: true))
        XCTAssertFalse(ClaudeAutoCompact.shouldCompact(ClaudeContextUsage(tokens: 160_000, model: "claude-opus-5[1m]"), resuming: true))
    }

    func testMeterReadsUsageWindowAndCompact() {
        var m = ClaudeContextMeter()
        for l in ClaudeDemoScript.usageLine(tokens: 170_000, window: 200_000) { m.read(l) }
        XCTAssertEqual(m.usage?.tokens, 170_000)
        XCTAssertEqual(m.usage?.window, 200_000)
        XCTAssertEqual(m.resultOk, true)
        XCTAssertFalse(m.compacted)
        var c = ClaudeContextMeter()
        for l in ClaudeDemoScript.compactLines(postTokens: 9_000) { c.read(l) }
        XCTAssertTrue(c.compacted)
        XCTAssertEqual(c.usage?.tokens, 9_000)
        // The synthetic "Prompt is too long" reply carries zero usage: it never resets the count.
        var o = ClaudeContextMeter()
        for l in ClaudeDemoScript.usageLine(tokens: 190_000) + ClaudeDemoScript.overflowLines() { o.read(l) }
        XCTAssertEqual(o.usage?.tokens, 190_000)
        XCTAssertEqual(o.resultOk, false)
    }

    func testCompactCommandKeepsIdsAndNeverQuotesLyrics() {
        let c = ClaudeAutoCompact.compactCommand
        XCTAssertTrue(c.hasPrefix("/compact "))
        XCTAssertFalse(c.contains("\n"), "one line: Claude Code reads the instructions after /compact")
        for w in ["edit session", "decisions", "approval", "style notes", "NEVER quote song lyrics", "captions track id"] {
            XCTAssertTrue(c.contains(w), w)
        }
    }

    // MARK: Handoff

    private static let lyric = ["I walked along the river in the rain", "Every light was calling out your name",
                                "Hold me now before the morning comes", "We were young and we were never done"]

    func testHandoffLeavesOutLyricsAndLongQuotes() {
        let t = 1_700_000_000.0
        func msg(_ i: Int, _ role: String, _ text: String) -> ClaudeMessage {
            ClaudeMessage(id: "m\(i)", threadId: "ct_1", role: role, source: "mac", text: text, createdAt: t + Double(i))
        }
        let lyrics = Self.lyric.joined(separator: "\n")
        let messages = [
            msg(0, "user", "Here are the words for the captions:\n\(lyrics)"),
            msg(1, "assistant", "I added them as captions on track ct_caps (items ci_1 to ci_4):\n\(Self.lyric.map { "- \($0)" }.joined(separator: "\n"))\nTell me if the timing feels off."),
            msg(2, "user", "Make the second line bigger. Use pink."),
            msg(3, "assistant", "Done. The line \"\(Self.lyric[1])\" is now 20% bigger and pink."),
            msg(4, "tool", "apply_edit_ops"),
            msg(5, "user", "> \(Self.lyric[2])\nThis one should fade in."),
            msg(6, "assistant", "```\n\(lyrics)\n```\nThat's the full set in the edit."),
            msg(7, "user", "Now sync to the beat"),
        ]
        let memory = [ClaudeMemoryRule(id: "mr_1", text: "Captions are always lowercase.", area: "edit", pinned: false, source: "person", characterId: nil)]
        let h = ClaudeAutoCompact.handoff(title: "Song captions", contextKind: "edit", contextId: "es_42", messages: messages, memory: memory,
                                          excluding: "Now sync to the beat")
        for l in Self.lyric {
            XCTAssertFalse(h.contains(l), "a lyric line survived: \(l)\n\(h)")
            // Not even half a line.
            XCTAssertFalse(h.contains(String(l.prefix(24))), "part of a lyric line survived: \(l)")
        }
        XCTAssertTrue(h.hasPrefix("[MUSE handoff]"))
        XCTAssertTrue(h.contains("Chat: Song captions"))
        XCTAssertTrue(h.contains("Working on: edit es_42"))
        XCTAssertTrue(h.contains("ct_caps"), "the ids stay")
        XCTAssertTrue(h.contains("Make the second line bigger. Use pink."))
        XCTAssertTrue(h.contains("This one should fade in."))
        XCTAssertTrue(h.contains("Captions are always lowercase."), "the person's memory goes along")
        XCTAssertTrue(h.contains("NEVER quote song lyrics"))
        XCTAssertFalse(h.contains("Now sync to the beat"), "the person's message follows the handoff, not inside it")
        XCTAssertFalse(h.contains("apply_edit_ops"), "tool steps are left out")
    }

    func testHandoffKeepsOnlyTheLastTenMessagesTrimmed() {
        let msgs = (0..<30).map { i in
            ClaudeMessage(id: "m\(i)", threadId: "ct_1", role: i % 2 == 0 ? "user" : "assistant", source: "mac",
                          text: "Message number \(i). " + String(repeating: "word ", count: 300), createdAt: Double(i))
        }
        let h = ClaudeAutoCompact.handoff(title: nil, contextKind: nil, contextId: nil, messages: msgs)
        XCTAssertFalse(h.contains("Message number 19."))
        XCTAssertTrue(h.contains("Message number 20."))
        XCTAssertTrue(h.contains("Message number 29."))
        for line in h.components(separatedBy: "\n") where line.hasPrefix("- ") {
            XCTAssertLessThanOrEqual(line.count, ClaudeAutoCompact.handoffMessageChars + 20)
        }
    }

    // MARK: Recovery and no loop (runner)

    func testFullChatCarriesOnOnceInAFreshSession() async throws {
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_42")
        _ = try await api.setClaudeSession(threadId: thread.id, claudeSessionId: "demo-session-1")
        let launcher = ClaudeScriptedLauncher()
        let runner = ClaudeTurnRunner(api: api, launcher: launcher, tokens: ClaudeTokenCache(), executable: "/x/claude", root: root, environment: [:], flushInterval: 0.01)
        let sink = Sink()
        let text = "Make the chorus pink \(ClaudeDemoScript.chatFullMarker)"
        let out = await runner.run(ClaudeRunRequest(threadId: thread.id, text: text, resume: "demo-session-1"),
                                   handoff: { "[MUSE handoff] Chat: Song captions" }) { sink.add($0) }
        XCTAssertTrue(out.ok, out.error ?? "")
        XCTAssertTrue(out.recovered)
        XCTAssertEqual(out.sessionId, ClaudeDemoScript.freshSessionId)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(Array(launcher.launches[0].arguments.suffix(2)), ["--resume", "demo-session-1"])
        XCTAssertFalse(launcher.launches[1].arguments.contains("--resume"), "the fresh session has no --resume")
        let second = Self.content(launcher.launches[1].stdin)
        XCTAssertTrue(second.hasPrefix("[MUSE handoff]"))
        XCTAssertTrue(second.hasSuffix(text), "the person's message goes again once, after the handoff")
        // The chat: one quiet line, no "Prompt is too long", one done (ok).
        let posted = api.allPostedEvents
        let notes = posted.filter { if case .tool(let id, _, _, let s, _) = $0 { return id.hasPrefix(ClaudeAutoCompact.freshSpacePrefix) && s == ClaudeAutoCompact.freshSpaceLine }; return false }
        XCTAssertEqual(notes.count, 1)
        XCTAssertFalse(posted.contains(.assistant(text: "Prompt is too long")))
        XCTAssertEqual(posted.filter { if case .done = $0 { return true }; return false }, [.done(ok: true, error: nil, model: "claude-sonnet-demo")])
        XCTAssertEqual(posted.filter { if case .user = $0 { return true }; return false }.count, 1, "the message is stored once")
        XCTAssertEqual(sink.dones.count, 1)
        // The chat's Claude Code session is now the fresh one.
        let d = try await api.threadDetail(thread.id)
        XCTAssertEqual(d.thread.claudeSessionId, ClaudeDemoScript.freshSessionId)
    }

    func testNoLoopWhenTheFreshSessionIsFullToo() async throws {
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_42")
        let launcher = ClaudeScriptedLauncher { _ in ClaudeDemoScript.overflowLines() }
        let runner = ClaudeTurnRunner(api: api, launcher: launcher, tokens: ClaudeTokenCache(), executable: "/x/claude", root: root, environment: [:], flushInterval: 0.01)
        let sink = Sink()
        let out = await runner.run(ClaudeRunRequest(threadId: thread.id, text: "again", resume: "demo-session-1"),
                                   handoff: { "[MUSE handoff]" }) { sink.add($0) }
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.error, ClaudeAutoCompact.fullError)
        XCTAssertEqual(launcher.launches.count, 2, "one recovery per turn, never a loop")
        XCTAssertEqual(sink.dones, [.done(ok: false, error: ClaudeAutoCompact.fullError, model: "claude-sonnet-demo")])
        XCTAssertEqual(api.allPostedEvents.filter { if case .done = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(ChatLeakFilter.errorWords(out.error), ClaudeAutoCompact.fullError)
    }

    func testWithoutAHandoffTheErrorIsPlain() async throws {
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_42")
        let launcher = ClaudeScriptedLauncher { _ in ClaudeDemoScript.overflowLines() }
        let runner = ClaudeTurnRunner(api: api, launcher: launcher, tokens: ClaudeTokenCache(), executable: "/x/claude", root: root, environment: [:], flushInterval: 0.01)
        let out = await runner.run(ClaudeRunRequest(threadId: thread.id, text: "again", resume: "demo-session-1")) { _ in }
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(out.error, ClaudeAutoCompact.fullError)
    }

    // MARK: Preventive compact (relay)

    private func relay(_ api: FakeClaudeAPI, _ launcher: ClaudeScriptedLauncher, _ sink: Sink) -> ClaudeRelay {
        let root = self.root!
        return ClaudeRelay(api: api, makeRunner: {
            ClaudeTurnRunner(api: api, launcher: launcher, tokens: ClaudeTokenCache(), executable: "/x", root: root, environment: [:], flushInterval: 0.01)
        }, onEvent: { _, _, e in sink.add(e) })
    }

    private func seedUsage(_ threadId: String, tokens: Int) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(threadId), withIntermediateDirectories: true)
        ClaudeTurnRunner.saveUsage(ClaudeContextUsage(tokens: tokens, window: 200_000), threadId: threadId, root: root)
    }

    func testAFullishChatIsCompactedBeforeTheNextMessage() async throws {
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_42")
        _ = try await api.setClaudeSession(threadId: thread.id, claudeSessionId: "demo-session-1")
        try seedUsage(thread.id, tokens: 160_000)
        let launcher = ClaudeScriptedLauncher()
        let sink = Sink()
        let r = relay(api, launcher, sink)
        await r.submit(threadId: thread.id, text: "Next caption please")
        try await waitFor { sink.dones.count == 1 }
        try await waitFor { await r.isRunning(threadId: thread.id) == false }
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(Self.content(launcher.launches[0].stdin), ClaudeAutoCompact.compactCommand)
        XCTAssertEqual(Array(launcher.launches[0].arguments.suffix(2)), ["--resume", "demo-session-1"])
        XCTAssertEqual(Self.content(launcher.launches[1].stdin), "Next caption please")
        XCTAssertEqual(Array(launcher.launches[1].arguments.suffix(2)), ["--resume", "demo-session-1"], "the same session, compacted")
        // The compact is silent: nothing of it in the chat.
        XCTAssertFalse(api.allPostedEvents.contains { if case .user(let t, _) = $0 { return t.hasPrefix("/compact") }; return false })
        XCTAssertFalse(sink.all.contains { if case .tool(let id, _, _, _, _) = $0 { return id.hasPrefix(ClaudeAutoCompact.freshSpacePrefix) }; return false })
    }

    func testABelowThresholdChatIsNotCompacted() async throws {
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_42")
        _ = try await api.setClaudeSession(threadId: thread.id, claudeSessionId: "demo-session-1")
        try seedUsage(thread.id, tokens: 100_000)
        let launcher = ClaudeScriptedLauncher()
        let sink = Sink()
        let r = relay(api, launcher, sink)
        await r.submit(threadId: thread.id, text: "hello")
        try await waitFor { sink.dones.count == 1 }
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testAFailedCompactStartsAFreshSessionWithTheHandoff() async throws {
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_42")
        _ = try await api.setClaudeSession(threadId: thread.id, claudeSessionId: "demo-session-1")
        try seedUsage(thread.id, tokens: 180_000)
        // Claude Code's compact is blocked (the owner's filter case): an error result, no compact_boundary.
        let launcher = ClaudeScriptedLauncher { text in text.hasPrefix("/compact") ? ClaudeDemoScript.overflowLines() : ClaudeDemoScript.lines(text) }
        let sink = Sink()
        let r = relay(api, launcher, sink)
        await r.submit(threadId: thread.id, text: "Next caption please")
        try await waitFor { sink.dones.count == 1 }
        try await waitFor { await r.isRunning(threadId: thread.id) == false }
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertFalse(launcher.launches[1].arguments.contains("--resume"))
        let sent = Self.content(launcher.launches[1].stdin)
        XCTAssertTrue(sent.hasPrefix("[MUSE handoff]"))
        XCTAssertTrue(sent.contains("Working on: edit es_42"))
        XCTAssertTrue(sent.hasSuffix("Next caption please"))
        XCTAssertEqual(sink.dones, [.done(ok: true, error: nil, model: "claude-sonnet-demo")])
        XCTAssertTrue(sink.all.contains { if case .tool(let id, _, _, _, _) = $0 { return id.hasPrefix(ClaudeAutoCompact.freshSpacePrefix) }; return false })
        let d = try await api.threadDetail(thread.id)
        XCTAssertEqual(d.thread.claudeSessionId, ClaudeDemoScript.freshSessionId)
    }
}
