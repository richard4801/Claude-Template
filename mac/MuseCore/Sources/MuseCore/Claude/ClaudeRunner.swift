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
    /// What the owner typed, when `text` carries more (the attached images' paths): the mirrored user message.
    public var shownText: String?
    /// The images typed with a Mac turn (the user event carries them so the phone shows them).
    public var uploadIds: [String] = []
    /// Where the turn's images were saved (Claude Code may Read there).
    public var readDirectory: String?
    /// Step 6b: the chat's Claude model (`--model`).
    public var model: String?
    /// The chat's effort level (`--effort`).
    public var effort: String?
    /// Files on this Mac (ask every time). Only the Mac's own turns: a phone turn has nobody at the Mac to answer.
    public var files = false
    /// Start a fresh Claude Code session seeded with MUSE's handoff (the chat was full and `/compact` didn't work).
    public var startFresh = false

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
    /// How full the session's context was at the end of the turn.
    public var usage: ClaudeContextUsage? = nil
    /// The chat was full and carried on in a fresh session (MUSE's handoff).
    public var recovered = false
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
    /// `handoff` builds MUSE's summary of the chat for a fresh session: with it, a turn that ends "prompt too long" carries on
    /// once in a fresh session (ClaudeAutoCompact); without it, that error ends the turn in plain words.
    public func run(_ req: ClaudeRunRequest, handoff: (@Sendable () async -> String)? = nil,
                    onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async -> ClaudeRunOutcome {
        let mirror = Mirror(api: api, threadId: req.threadId, turnId: req.turnId)
        if req.turnId == nil {
            let u = ClaudeEvent.user(text: req.shownText ?? req.text, attachments: req.uploadIds)
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

        let token: McpSessionToken, config: URL
        switch await prepare(req) {
        case .failure(let e): return await fail(e.message)
        case .success(let p): (token, config) = p
        }
        defer { try? FileManager.default.removeItem(at: config) }

        // The quiet line, then the handoff and the person's message as one message to a fresh session (no --resume).
        func freshStart() async -> ClaudeRunRequest {
            let note = ClaudeEvent.tool(id: ClaudeAutoCompact.freshSpacePrefix + UUID().uuidString.prefix(8).lowercased(), name: "MUSE",
                                        status: .done, summary: ClaudeAutoCompact.freshSpaceLine, input: nil)
            onEvent(note)
            await mirror.add(note)
            var f = req
            f.resume = nil
            f.text = (await handoff?() ?? "") + "\n\n" + req.text
            return f
        }

        var first = req
        var recovered = false
        if req.startFresh, handoff != nil {
            first = await freshStart()
            recovered = true
        }
        // One recovery per turn: a turn that already started fresh is never recovered again.
        let recoverable = handoff != nil && !recovered
        var attempt = try? await once(first, token: token, config: config, resume: first.resume, recoverable: recoverable, mirror: mirror, onEvent: onEvent)
        // A session id this Mac doesn't know (another Mac, a cleared ~/.claude): start the conversation afresh once.
        if let a = attempt, a.retryFresh {
            attempt = try? await once(first, token: token, config: config, resume: nil, recoverable: recoverable, mirror: mirror, onEvent: onEvent)
        }
        // The chat no longer fits (Claude Code's own compact failed too): carry on once in a fresh session.
        if let a = attempt, a.overflow {
            let fresh = await freshStart()
            recovered = true
            attempt = try? await once(fresh, token: token, config: config, resume: nil, recoverable: false, mirror: mirror, onEvent: onEvent)
        }
        guard var result = attempt else { return await fail("Couldn't start Claude Code") }
        result.outcome.recovered = recovered
        if let u = result.outcome.usage { Self.saveUsage(u, threadId: req.threadId, root: root) }
        await mirror.flushAll()
        return result.outcome
    }

    /// Mints (or reuses) the token and writes the private mcp config for this run.
    private func prepare(_ req: ClaudeRunRequest) async -> Result<(McpSessionToken, URL), ApiError> {
        let token: McpSessionToken
        do { token = try await tokens.token(api) } catch {
            return .failure(ApiError("token", "Couldn't get a MUSE token for Claude: \((error as? ApiError)?.message ?? error.localizedDescription)"))
        }
        let dir = root.appendingPathComponent(req.threadId, isDirectory: true)
        let config = dir.appendingPathComponent(".mcp-\(UUID().uuidString.lowercased()).json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Self.writePrivate(command(req, token: token, resume: req.resume).mcpConfigJSON(), to: config)
        } catch {
            return .failure(ApiError("io", "Couldn't prepare ~/MUSE/Claude: \(error.localizedDescription)"))
        }
        return .success((token, config))
    }

    private func command(_ req: ClaudeRunRequest, token: McpSessionToken, resume: String?) -> ClaudeCommand {
        var cmd = ClaudeCommand(mcpURL: token.mcpUrl, token: token.token, blender: req.blender, resume: resume, appendSystemPrompt: req.systemPrompt)
        cmd.readDirectory = req.readDirectory
        cmd.model = req.model
        cmd.effort = req.effort
        cmd.files = req.files && req.turnId == nil
        return cmd
    }

    // MARK: Compact (ClaudeAutoCompact step 1)

    /// Runs Claude Code's own `/compact` with MUSE's instructions on the chat's session, silently (nothing in the chat or the
    /// mirror). True when Claude Code reported the compact done (`system/compact_boundary` and a success result).
    public func compact(_ req: ClaudeRunRequest) async -> Bool {
        guard let resume = req.resume, !resume.isEmpty, !isStopping else { return false }
        guard case .success(let (token, config)) = await prepare(req) else { return false }
        defer { try? FileManager.default.removeItem(at: config) }
        let cmd = command(req, token: token, resume: resume)
        let (lines, cont) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        guard let h = try? launcher.launch(executable: executable, arguments: cmd.arguments(configPath: config.path), cwd: config.deletingLastPathComponent(),
                                           environment: environment, stdin: ClaudeCommand.stdinLine(ClaudeAutoCompact.compactCommand),
                                           onLine: { cont.yield($0) }, onExit: { _, _ in cont.finish() }) else { return false }
        let stopNow: Bool = lock.claudeLocked {
            handle = h
            return stopRequested
        }
        if stopNow { stop() }
        defer { lock.claudeLocked { handle = nil } }
        var meter = ClaudeContextMeter()
        for await line in lines { meter.read(line) }
        let ok = meter.compacted && meter.resultOk != false && !isStopping
        if ok, let u = meter.usage { Self.saveUsage(u, threadId: req.threadId, root: root) }
        return ok
    }

    // MARK: Context use, kept beside the chat's run folder (a restart of MUSE still knows how full a chat is)

    static func usageURL(threadId: String, root: URL) -> URL {
        root.appendingPathComponent(threadId, isDirectory: true).appendingPathComponent(".context.json")
    }

    public func savedUsage(threadId: String) -> ClaudeContextUsage? {
        guard let d = try? Data(contentsOf: Self.usageURL(threadId: threadId, root: root)) else { return nil }
        return try? JSONDecoder().decode(ClaudeContextUsage.self, from: d)
    }

    static func saveUsage(_ u: ClaudeContextUsage, threadId: String, root: URL) {
        guard let d = try? JSONEncoder().encode(u) else { return }
        try? d.write(to: usageURL(threadId: threadId, root: root), options: .atomic)
    }

    private struct Attempt {
        var outcome: ClaudeRunOutcome
        var retryFresh: Bool
        /// The turn ended "prompt too long" and its done was held back for a recovery.
        var overflow = false
    }

    private func once(_ req: ClaudeRunRequest, token: McpSessionToken, config: URL, resume: String?, recoverable: Bool, mirror: Mirror,
                      onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async throws -> Attempt {
        let cmd = command(req, token: token, resume: resume)
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
        var meter = ClaudeContextMeter()
        var storedSession = resume
        var sawInit = false
        var overflow = false
        var finalError: String?
        // A done that says the chat no longer fits: held back when this turn may still recover, else said in plain words.
        func emit(_ e: ClaudeEvent) async {
            var e = e
            // Claude Code also says the error as a short reply of its own ("Prompt is too long"): not shown as Claude's words.
            if case .assistant(let t) = e, t.count < 400, ClaudeAutoCompact.isContextOverflow(t) { return }
            if case .done(false, let err, let model) = e, ClaudeAutoCompact.isContextOverflow(err) {
                if recoverable && !isStopping {
                    overflow = true
                    return
                }
                e = .done(ok: false, error: ClaudeAutoCompact.fullError, model: model)
                finalError = ClaudeAutoCompact.fullError
            }
            onEvent(e)
            await mirror.add(e)
        }
        for await line in lines {
            meter.read(line)
            for se in ClaudeStreamParser.parse(line) {
                if case .initialized = se { sawInit = true }
                for e in mapper.map(se) { await emit(e) }
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
            await emit(done)
        }
        var ok = false, error: String?
        if case .done(let o, let e, _)? = mapper.finished { ok = o; error = finalError ?? e }
        if stopped, !ok { error = "Stopped" }
        return Attempt(outcome: ClaudeRunOutcome(ok: ok, error: error, stopped: stopped, sessionId: mapper.sessionId, model: mapper.model, usage: meter.usage),
                       retryFresh: false, overflow: overflow && !stopped)
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
