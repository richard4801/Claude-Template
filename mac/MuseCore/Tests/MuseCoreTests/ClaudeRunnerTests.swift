import Foundation
import XCTest
@testable import MuseCore

/// The Mac runner: turns mirrored to the (fake) server, phone turns claimed and answered with their turnId, Stop, and the real
/// Process path against a fake `claude` executable that replays the recorded transcript. No real Claude calls.
final class ClaudeRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, String?, ClaudeEvent)] = []
        func add(_ t: String, _ turn: String?, _ e: ClaudeEvent) { lock.lock(); items.append((t, turn, e)); lock.unlock() }
        var all: [(String, String?, ClaudeEvent)] { lock.lock(); defer { lock.unlock() }; return items }
        var dones: Int { all.filter { if case .done = $0.2 { return true }; return false }.count }
    }

    private func scripted(_ delay: Double = 0) throws -> ClaudeScriptedLauncher {
        let lines = try ClaudeTests.fixtureLines()
        return ClaudeScriptedLauncher(delay: delay) { _ in lines }
    }

    private func waitFor(_ timeout: Double = 10, _ cond: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out")
    }

    // MARK: Runner with a scripted stream

    func testLocalTurnMirrorsEverythingAndStoresTheSession() async throws {
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_1")
        let launcher = try scripted()
        let runner = ClaudeTurnRunner(api: api, launcher: launcher, tokens: ClaudeTokenCache(), executable: "/x/claude", root: root, environment: [:], flushInterval: 0.01)
        let sink = Sink()
        let out = await runner.run(ClaudeRunRequest(threadId: thread.id, text: "Trim the start")) { sink.add(thread.id, nil, $0) }
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.sessionId, "5f1c2a9e-7d1b-4c1e-9a55-3c2f9b8e1d01")
        XCTAssertEqual(out.model, "claude-sonnet-4-5-20250929")
        // Mirrored in order, user first, done last, deltas merged, no turnId on the Mac's own turn.
        let posted = api.allPostedEvents
        XCTAssertEqual(posted.first, .user(text: "Trim the start"))
        XCTAssertEqual(posted.last, .done(ok: true, error: nil, model: "claude-sonnet-4-5-20250929"))
        XCTAssertTrue(api.posted.allSatisfy { $0.batch.turnId == nil })
        let text = posted.compactMap { if case .text(let d) = $0 { return d }; return nil }.joined()
        XCTAssertEqual(text, "Let me look at the edit.Trimmed 0:03–0:05; the draft is $1.92.")
        XCTAssertEqual(posted.filter { if case .image = $0 { return true }; return false }.count, 1)
        // The UI saw the same stream.
        XCTAssertEqual(sink.dones, 1)
        // The session id is on the thread; the stored transcript has user, assistant, tools and the image.
        let d = try await api.threadDetail(thread.id)
        XCTAssertEqual(d.thread.claudeSessionId, out.sessionId)
        XCTAssertEqual(d.messages.map(\.role), ["user", "assistant", "tool", "tool", "tool", "tool", "tool", "assistant"])
        // The command line and the private config (deleted afterwards).
        let launch = try XCTUnwrap(launcher.launches.first)
        XCTAssertEqual(launch.cwd.lastPathComponent, thread.id)
        XCTAssertEqual(launch.config, #"{"mcpServers":{"muse":{"headers":{"Authorization":"Bearer muse_oat_fake1"},"type":"http","url":"https://muse.test/mcp"}}}"#)
        XCTAssertFalse(launch.arguments.contains("--resume"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: launch.cwd.path).filter { $0.hasPrefix(".mcp-") }, [])
        XCTAssertEqual(launch.stdin, ClaudeCommand.stdinLine("Trim the start"))
    }

    func testTokenFailureEndsTheTurnWithDone() async throws {
        final class NoTokenAPI: ClaudeAPI, @unchecked Sendable {
            let inner = FakeClaudeAPI()
            func status() async throws -> ClaudeStatus { try await inner.status() }
            func setApiFallback(_ on: Bool) async throws -> ClaudeStatus { try await inner.setApiFallback(on) }
            func heartbeat(_ info: ClaudeCodeInfo) async throws -> ClaudeHeartbeatReply { try await inner.heartbeat(info) }
            func thread(contextKind: String, contextId: String) async throws -> ClaudeThread { try await inner.thread(contextKind: contextKind, contextId: contextId) }
            func threadDetail(_ id: String) async throws -> ClaudeThreadDetail { try await inner.threadDetail(id) }
            func setClaudeSession(threadId: String, claudeSessionId: String) async throws -> ClaudeThread { try await inner.setClaudeSession(threadId: threadId, claudeSessionId: claudeSessionId) }
            func postMessage(threadId: String, text: String) async throws -> ClaudeMessagePosted { try await inner.postMessage(threadId: threadId, text: text) }
            func pendingTurns() async throws -> [ClaudeTurn] { [] }
            func claim(turnId: String) async throws -> ClaudeTurn { try await inner.claim(turnId: turnId) }
            func stopTurn(_ turnId: String) async throws {}
            func postEvents(threadId: String, _ batch: ClaudeEventBatch) async throws { try await inner.postEvents(threadId: threadId, batch) }
            func apiTurn(threadId: String, text: String) -> AsyncThrowingStream<ChatEvent, Error> { inner.apiTurn(threadId: threadId, text: text) }
            func mcpSessionToken(ttlMinutes: Int?) async throws -> McpSessionToken { throw ApiError("owner_only", "Owner only") }
            func events() -> AsyncStream<ClaudeLiveEvent> { inner.events() }
        }
        let api = NoTokenAPI()
        let t = try await api.thread(contextKind: "camera", contextId: "cs_1")
        let launcher = try scripted()
        let runner = ClaudeTurnRunner(api: api, launcher: launcher, tokens: ClaudeTokenCache(), executable: "/x", root: root, environment: [:], flushInterval: 0.01)
        let out = await runner.run(ClaudeRunRequest(threadId: t.id, text: "hi")) { _ in }
        XCTAssertFalse(out.ok)
        XCTAssertEqual(api.inner.allPostedEvents.last, .done(ok: false, error: "Couldn't get a MUSE token for Claude: Owner only", model: nil))
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    // MARK: Relay

    func testPhoneTurnIsClaimedAnsweredWithTurnIdAndResumed() async throws {
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_1")
        _ = try await api.setClaudeSession(threadId: thread.id, claudeSessionId: "earlier-session")
        let launcher = try scripted()
        let sink = Sink()
        let root = self.root!
        let relay = ClaudeRelay(api: api, makeRunner: {
            ClaudeTurnRunner(api: api, launcher: launcher, tokens: ClaudeTokenCache(), executable: "/x", root: root, environment: [:], flushInterval: 0.01)
        }, onEvent: { sink.add($0, $1, $2) })
        let turn = api.queuePhoneTurn(threadId: thread.id, text: "Make it warmer")
        await relay.offer([turn])
        await relay.offer(try await api.pendingTurns()) // heartbeat repeats it: ignored
        try await waitFor { sink.dones == 1 }
        try await waitFor { await relay.isRunning(threadId: thread.id) == false }
        XCTAssertEqual(api.claims, [turn.id])
        XCTAssertEqual(api.turn(turn.id)?.state, "done")
        XCTAssertTrue(api.posted.allSatisfy { $0.batch.turnId == turn.id })
        XCTAssertFalse(api.allPostedEvents.contains(.user(text: "Make it warmer")), "the server already has the phone's message")
        XCTAssertTrue(sink.all.allSatisfy { $0.1 == turn.id })
        let args = try XCTUnwrap(launcher.launches.first?.arguments)
        XCTAssertEqual(Array(args.suffix(2)), ["--resume", "earlier-session"])
        // The next turn resumes the session Claude Code reported.
        await relay.submit(threadId: thread.id, text: "Again")
        try await waitFor { sink.dones == 2 }
        XCTAssertEqual(Array(launcher.launches[1].arguments.suffix(2)), ["--resume", "5f1c2a9e-7d1b-4c1e-9a55-3c2f9b8e1d01"])
    }

    func testClaimRefusedTurnIsNotRun() async throws {
        let api = FakeClaudeAPI()
        api.claimError = "already_claimed"
        let thread = try await api.thread(contextKind: "camera", contextId: "cs_1")
        let launcher = try scripted()
        let root = self.root!
        let relay = ClaudeRelay(api: api, makeRunner: {
            ClaudeTurnRunner(api: api, launcher: launcher, tokens: ClaudeTokenCache(), executable: "/x", root: root, environment: [:], flushInterval: 0.01)
        }, onEvent: { _, _, _ in })
        await relay.offer([api.queuePhoneTurn(threadId: thread.id, text: "hi")])
        try await waitFor { api.claims.count == 1 }
        try await waitFor { await relay.isRunning(threadId: thread.id) == false }
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertTrue(api.posted.isEmpty)
    }

    func testStopEndsTheRunningTurnAndDropsAWaitingOne() async throws {
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_1")
        let launcher = try scripted(0.05) // ~1 s for the whole transcript
        let sink = Sink()
        let root = self.root!
        let states = Sink()
        let relay = ClaudeRelay(api: api, makeRunner: {
            ClaudeTurnRunner(api: api, launcher: launcher, tokens: ClaudeTokenCache(), executable: "/x", root: root, environment: [:], flushInterval: 0.01, stopGrace: 0.2)
        }, onEvent: { sink.add($0, $1, $2) }, onState: { s in states.add("state", s.answeringFromPhone ? "phone" : nil, .text(delta: "")) })
        let first = api.queuePhoneTurn(threadId: thread.id, text: "one")
        await relay.offer([first])
        try await waitFor { sink.all.count >= 2 }
        let second = ClaudeTurn(id: "tu_waiting", threadId: thread.id, text: "two", createdAt: 1)
        await relay.offer([second])
        let queued = await relay.state.queued[thread.id]
        XCTAssertEqual(queued, 1)
        XCTAssertTrue(states.all.contains { $0.1 == "phone" }, "Answering from your phone")
        await relay.stop(turnId: "tu_waiting")
        await relay.stop(turnId: first.id)
        try await waitFor { sink.dones == 1 }
        try await waitFor { await relay.isRunning(threadId: thread.id) == false }
        XCTAssertEqual(sink.all.last?.2, .done(ok: false, error: "Stopped", model: "claude-sonnet-4-5-20250929"))
        XCTAssertEqual(api.turn(first.id)?.state, "stopped")
        XCTAssertEqual(launcher.launches.count, 1, "the waiting turn was dropped")
    }

    // MARK: Real Process + fake claude

    private func fakeClaude() throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/bin/bash") else { throw XCTSkip("no /bin/bash") }
        let src = try XCTUnwrap(Bundle.module.url(forResource: "fake-claude", withExtension: nil, subdirectory: "Fixtures/claude"))
        let dst = root.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: dst)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        return dst.path
    }

    private func env(_ extra: [String: String]) throws -> [String: String] {
        let transcript = try XCTUnwrap(Bundle.module.url(forResource: "claude-stream", withExtension: "jsonl", subdirectory: "Fixtures/claude"))
        var e = ["PATH": "/usr/bin:/bin", "HOME": root.path, "FAKE_CLAUDE_TRANSCRIPT": transcript.path]
        for (k, v) in extra { e[k] = v }
        return e
    }

    func testProbeReadsVersionAndSignIn() async throws {
        let exe = try fakeClaude()
        let ok = await ClaudeShell.probe(executable: exe, environment: try env([:]))
        XCTAssertEqual(ok, ClaudeCodeInfo(installed: true, signedIn: true, version: "2.1.211"))
        let out = await ClaudeShell.probe(executable: exe, environment: try env(["FAKE_CLAUDE_SIGNED_OUT": "1"]))
        XCTAssertEqual(out, ClaudeCodeInfo(installed: true, signedIn: false, version: "2.1.211"))
        let missing = await ClaudeShell.probe(executable: root.appendingPathComponent("nope").path, environment: [:])
        XCTAssertFalse(missing.installed)
        XCTAssertEqual(ClaudeCodeLocator.find(home: "/nowhere", path: (exe as NSString).deletingLastPathComponent), exe)
    }

    func testProcessRunReplaysTranscriptWithAPrivateConfig() async throws {
        let exe = try fakeClaude()
        let log = root.appendingPathComponent("args.log").path
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_1")
        let runner = ClaudeTurnRunner(api: api, tokens: ClaudeTokenCache(), executable: exe, root: root.appendingPathComponent("Claude"),
                                      environment: try env(["FAKE_CLAUDE_LOG": log]), flushInterval: 0.02)
        let sink = Sink()
        let out = await runner.run(ClaudeRunRequest(threadId: thread.id, text: "Trim the start", blender: .init(uvx: "/usr/bin/uvx"))) { sink.add(thread.id, nil, $0) }
        XCTAssertTrue(out.ok, out.error ?? "")
        XCTAssertEqual(api.allPostedEvents.last, .done(ok: true, error: nil, model: "claude-sonnet-4-5-20250929"))
        XCTAssertEqual(sink.all.filter { if case .tool = $0.2 { return true }; return false }.count, 8)
        let logged = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let args = logged.filter { $0.hasPrefix("ARG:") }.map { String($0.dropFirst(4)) }
        XCTAssertEqual(args[0...6], ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"])
        XCTAssertTrue(args.contains("mcp__blender"))
        XCTAssertTrue(logged.contains("MODE:600"))
        XCTAssertTrue(logged.contains { $0.hasPrefix("CONFIG:") && $0.contains("Bearer muse_oat_fake1") && $0.contains("mcp-for-blender") })
        XCTAssertTrue(logged.contains { $0.hasPrefix("CWD:") && $0.hasSuffix("/Claude/\(thread.id)") })
        XCTAssertTrue(logged.contains("STDIN:" + ClaudeCommand.stdinLine("Trim the start").dropLast()))
        let dir = root.appendingPathComponent("Claude/\(thread.id)").path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix(".mcp-") }, [], "config deleted")
    }

    func testProcessStopSendsSigint() async throws {
        let exe = try fakeClaude()
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_1")
        let runner = ClaudeTurnRunner(api: api, tokens: ClaudeTokenCache(), executable: exe, root: root.appendingPathComponent("Claude"),
                                      environment: try env(["FAKE_CLAUDE_HANG": "1"]), flushInterval: 0.02, stopGrace: 5)
        let sink = Sink()
        let started = Date()
        let task = Task { await runner.run(ClaudeRunRequest(threadId: thread.id, text: "hang")) { sink.add(thread.id, nil, $0) } }
        try await waitFor { (try? await api.threadDetail(thread.id))?.thread.claudeSessionId != nil }
        runner.stop()
        let out = await task.value
        XCTAssertTrue(out.stopped)
        XCTAssertEqual(out.error, "Stopped")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5, "ended by SIGINT, not the SIGTERM fallback")
        XCTAssertEqual(api.allPostedEvents.last, .done(ok: false, error: "Stopped", model: "claude-sonnet-4-5-20250929"))
    }

    func testUnknownResumeSessionStartsAfresh() async throws {
        let exe = try fakeClaude()
        let log = root.appendingPathComponent("resume.log").path
        let api = FakeClaudeAPI()
        let thread = try await api.thread(contextKind: "edit", contextId: "es_1")
        let runner = ClaudeTurnRunner(api: api, tokens: ClaudeTokenCache(), executable: exe, root: root.appendingPathComponent("Claude"),
                                      environment: try env(["FAKE_CLAUDE_NO_SESSION": "1", "FAKE_CLAUDE_LOG": log]), flushInterval: 0.02)
        let out = await runner.run(ClaudeRunRequest(threadId: thread.id, text: "hi", resume: "from-another-mac")) { _ in }
        XCTAssertTrue(out.ok, out.error ?? "")
        let logged = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertEqual(logged.components(separatedBy: "ARG:--resume").count, 2, "tried once with --resume, then without")
        XCTAssertEqual(api.allPostedEvents.filter { if case .done = $0 { return true }; return false }.count, 1)
    }
}
