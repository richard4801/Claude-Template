import Foundation

public struct ClaudeRunRequest: Hashable, Sendable {
    public var threadId: String
    /// A claimed phone turn (its events carry the turnId); nil for the Mac's own turns.
    public var turnId: String?
    public var text: String
    /// Claude Code's session id to `--resume`.
    public var resume: String?
    public var blender: ClaudeCommand.Blender?
    /// The thread's brief as a system prompt (recreate and edit threads; workstream 1).
    public var systemPrompt: String?

    public init(threadId: String, turnId: String? = nil, text: String, resume: String? = nil, blender: ClaudeCommand.Blender? = nil,
                systemPrompt: String? = nil) {
        self.threadId = threadId
        self.turnId = turnId
        self.text = text
        self.resume = resume
        self.blender = blender
        self.systemPrompt = systemPrompt
    }
}

public struct ClaudeRunOutcome: Hashable, Sendable {
    public var ok: Bool
    public var error: String?
    public var stopped: Bool
    public var sessionId: String?
    public var model: String?
}

/// Runs one turn of headless Claude Code and mirrors it: mints (or reuses) the MCP session token, writes the 0600 mcp config
/// in ~/MUSE/Claude/<threadId>/, starts the process there, maps its stream to ClaudeEvents for the UI, posts them to
/// POST …/events in batches every ~300 ms, stores Claude Code's session id on the thread, and always ends with `done`.
/// The config file is deleted when the run ends. Stop = SIGINT, then SIGTERM after 5 s.
public final class ClaudeTurnRunner: @unchecked Sendable {
    public let api: any ClaudeAPI
    public let launcher: any ClaudeLauncher
    public let tokens: ClaudeTokenCache
    public let executable: String
    public let root: URL
    public let environment: [String: String]
    public let flushInterval: Double
    public let stopGrace: Double

    private let lock = NSLock()
    private var handle: (any ClaudeProcessHandle)?
    private var stopRequested = false

    /// ~/MUSE/Claude
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MUSE", isDirectory: true).appendingPathComponent("Claude", isDirectory: true)
    }

    public init(api: any ClaudeAPI, launcher: any ClaudeLauncher = ProcessLauncher(), tokens: ClaudeTokenCache, executable: String,
                root: URL = ClaudeTurnRunner.defaultRoot, environment: [String: String], flushInterval: Double = 0.3, stopGrace: Double = 5) {
        self.api = api
        self.launcher = launcher
        self.tokens = tokens
        self.executable = executable
        self.root = root
        self.environment = environment
        self.flushInterval = flushInterval
        self.stopGrace = stopGrace
    }

    public var isStopping: Bool { lock.claudeLocked { stopRequested } }

    /// Ends the turn: SIGINT now, SIGTERM after the grace period if Claude Code is still running.
    public func stop() {
        let h: (any ClaudeProcessHandle)? = lock.claudeLocked {
            stopRequested = true
            return handle
        }
        guard let h else { return }
        h.interrupt()
        let grace = stopGrace
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { if h.isRunning { h.terminate() } }
    }

    /// Runs the turn to its end. `onEvent` gets every event as it happens (on a background task).
    public func run(_ req: ClaudeRunRequest, onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async -> ClaudeRunOutcome {
        let mirror = Mirror(api: api, threadId: req.threadId, turnId: req.turnId)
        if req.turnId == nil {
            let u = ClaudeEvent.user(text: req.text)
            onEvent(u)
            await mirror.add(u)
        }
        let flusher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
                await mirror.flush()
            }
        }
        defer { flusher.cancel() }

        func fail(_ message: String) async -> ClaudeRunOutcome {
            let done = ClaudeEvent.done(ok: false, error: message, model: nil)
            onEvent(done)
            await mirror.add(done)
            await mirror.flushAll()
            return ClaudeRunOutcome(ok: false, error: message, stopped: false)
        }

        let token: McpSessionToken
        do { token = try await tokens.token(api) } catch {
            return await fail("Couldn't get a MUSE token for Claude: \((error as? ApiError)?.message ?? error.localizedDescription)")
        }
        let dir = root.appendingPathComponent(req.threadId, isDirectory: true)
        let config = dir.appendingPathComponent(".mcp-\(UUID().uuidString.lowercased()).json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let cmd = ClaudeCommand(mcpURL: token.mcpUrl.isEmpty ? "" : token.mcpUrl, token: token.token, blender: req.blender, resume: req.resume, appendSystemPrompt: req.systemPrompt)
            try Self.writePrivate(cmd.mcpConfigJSON(), to: config)
        } catch {
            return await fail("Couldn't prepare ~/MUSE/Claude: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: config) }

        var attempt = try? await once(req, token: token, config: config, resume: req.resume, mirror: mirror, onEvent: onEvent)
        // A session id this Mac doesn't know (another Mac, a cleared ~/.claude): start the conversation afresh once.
        if let a = attempt, a.retryFresh {
            attempt = try? await once(req, token: token, config: config, resume: nil, mirror: mirror, onEvent: onEvent)
        }
        guard let result = attempt else { return await fail("Couldn't start Claude Code") }
        await mirror.flushAll()
        return result.outcome
    }

    private struct Attempt {
        var outcome: ClaudeRunOutcome
        var retryFresh: Bool
    }

    private func once(_ req: ClaudeRunRequest, token: McpSessionToken, config: URL, resume: String?, mirror: Mirror,
                      onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async throws -> Attempt {
        let cmd = ClaudeCommand(mcpURL: token.mcpUrl, token: token.token, blender: req.blender, resume: resume, appendSystemPrompt: req.systemPrompt)
        let (lines, cont) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        let exit = ExitBox()
        let h = try launcher.launch(executable: executable, arguments: cmd.arguments(configPath: config.path), cwd: config.deletingLastPathComponent(),
                                    environment: environment, stdin: ClaudeCommand.stdinLine(req.text),
                                    onLine: { cont.yield($0) },
                                    onExit: { code, err in
                                        exit.set(code, err)
                                        cont.finish()
                                    })
        let stopNow: Bool = lock.claudeLocked {
            handle = h
            return stopRequested
        }
        if stopNow { stop() }
        defer { lock.claudeLocked { handle = nil } }

        var mapper = ClaudeEventMapper()
        var storedSession = resume
        var sawInit = false
        for await line in lines {
            for se in ClaudeStreamParser.parse(line) {
                if case .initialized = se { sawInit = true }
                for e in mapper.map(se) {
                    onEvent(e)
                    await mirror.add(e)
                }
                if let sid = mapper.sessionId, sid != storedSession {
                    storedSession = sid
                    _ = try? await api.setClaudeSession(threadId: req.threadId, claudeSessionId: sid)
                }
            }
        }
        let (code, stderr) = exit.get()
        let stopped = isStopping
        if mapper.finished == nil {
            if !sawInit, !stopped, resume != nil, stderr.localizedCaseInsensitiveContains("no conversation found") {
                return Attempt(outcome: ClaudeRunOutcome(ok: false, error: nil, stopped: false), retryFresh: true)
            }
            let done = mapper.finishWithoutResult(stopped: stopped, exitCode: code, stderr: stderr)
            onEvent(done)
            await mirror.add(done)
        }
        var ok = false, error: String?
        if case .done(let o, let e, _)? = mapper.finished { ok = o; error = e }
        if stopped, !ok { error = "Stopped" }
        return Attempt(outcome: ClaudeRunOutcome(ok: ok, error: error, stopped: stopped, sessionId: mapper.sessionId, model: mapper.model), retryFresh: false)
    }

    /// Creates the file 0600 first, then writes it (the token never sits in a world-readable file).
    static func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ApiError("io", "Couldn't write \(url.lastPathComponent)")
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        h.write(data)
    }

    final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var code: Int32 = 0
        private var err = ""
        func set(_ c: Int32, _ e: String) { lock.claudeLocked { code = c; err = e } }
        func get() -> (Int32, String) { lock.claudeLocked { (code, err) } }
    }

    /// The server mirror: batches events and posts them in order (never two posts at once).
    actor Mirror {
        let api: any ClaudeAPI
        let threadId: String
        let turnId: String?
        var batcher = ClaudeEventBatcher()
        var posting = false
        var failures = 0

        init(api: any ClaudeAPI, threadId: String, turnId: String?) {
            self.api = api
            self.threadId = threadId
            self.turnId = turnId
        }

        func add(_ e: ClaudeEvent) { batcher.add(e) }

        func flush() async {
            guard !posting, !batcher.isEmpty else { return }
            posting = true
            defer { posting = false }
            for b in batcher.drain(turnId: turnId) {
                do { try await api.postEvents(threadId: threadId, b) } catch {
                    // The mirror is best effort: the local run goes on; the transcript reloads from the server later.
                    failures += 1
                }
            }
        }

        /// Waits for a post in flight, then sends the rest.
        func flushAll() async {
            while posting { try? await Task.sleep(nanoseconds: 20_000_000) }
            await flush()
        }
    }
}

extension NSLock {
    func claudeLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
