// Claude on the owner's plan (plans/claude-editing.md C–D; plans/api.md "Claude on the owner's plan").
// Wired from BlenderRelayService.configure / stop (workstream 2), so AppStore stays untouched:
//     ClaudeCodeService.shared.configure(baseURL:isOwner:token:) after sign-in; .stop() on sign-out.
// Demo mode (no HTTP API) runs a scripted Claude Code stream against FakeClaudeAPI; a member never runs it.

import AppKit
import Combine
import Foundation
import MuseCore

/// The Mac runner for Claude chat: finds Anthropic's Claude Code (signed in to the owner's subscription; MUSE never reads its
/// credentials), runs each turn headless through ClaudeRelay, mirrors it to the server, heartbeats every 20 s with the install
/// state, and answers the phone's turns (live `claude` `{op: "turn"}` + catch-up) one at a time per thread.
@MainActor
final class ClaudeCodeService: ObservableObject {
    static let shared = ClaudeCodeService()

    /// What the chat views and the Connections section listen to.
    enum Feed: Sendable {
        /// A `claude` live event from the server (echoes of this Mac's own running turns are filtered out).
        case live(ClaudeLiveEvent)
        /// This Mac's Claude Code stream for a thread.
        case local(threadId: String, turnId: String?, ClaudeEvent)
    }

    @Published private(set) var info = ClaudeCodeInfo()
    @Published private(set) var executable: String?
    @Published private(set) var checking = false
    @Published private(set) var checkedOnce = false
    @Published private(set) var status: ClaudeStatus?
    @Published private(set) var relayState = ClaudeRelayState()
    @Published private(set) var lastError: String?
    /// Signed in as the owner (or demo mode): the chat can run.
    @Published private(set) var configured = false
    @Published private(set) var isDemo = false
    @Published private(set) var isOwner = false

    private(set) var api: (any ClaudeAPI)?
    private(set) var baseURL: URL?
    private var relay: ClaudeRelay?
    private var loops: [Task<Void, Never>] = []
    private var pollTask: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<Feed>.Continuation] = [:]
    private var tokens = ClaudeTokenCache()
    private var activeObserver: NSObjectProtocol?
    /// Phone turns this Mac ran: their `{op: "event"}` echoes from the server are dropped (the local stream showed them).
    private var ranTurns: Set<String> = []
    private static let demoAPI = FakeClaudeAPI()
    /// Demo mode: seconds between the scripted reply's lines (review mode slows it to close a chat mid-reply).
    static var demoLineDelay = 0.12

    init() {}

    // MARK: Wiring

    /// After sign-in / reconnect. A different server restarts it; no server = demo mode.
    func configure(baseURL: URL?, isOwner: Bool, token: @escaping @Sendable () -> String?) {
        let demo = baseURL == nil
        if configured, baseURL == self.baseURL, isOwner == self.isOwner, demo == isDemo { return }
        stop()
        self.isOwner = isOwner
        // One Claude (owner, 2026-11-11): every member runs Claude Code on their own Claude plan too; the server gives
        // their connection members' tools only.
        self.baseURL = baseURL
        isDemo = demo
        if let baseURL {
            api = HTTPClaudeAPI(baseURL: baseURL, token: token)
        } else {
            api = Self.demoAPI
        }
        configured = true
        start()
    }

    func stop() {
        loops.forEach { $0.cancel() }
        loops = []
        pollTask?.cancel()
        pollTask = nil
        if let relay { Task { await relay.close() } }
        relay = nil
        api = nil
        status = nil
        relayState = ClaudeRelayState()
        configured = false
        tokens = ClaudeTokenCache()
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        activeObserver = nil
    }

    private func start() {
        guard let api else { return }
        // Events from the relay's background tasks arrive here in order through one stream.
        let (events, sink) = AsyncStream<(String, String?, ClaudeEvent)>.makeStream(bufferingPolicy: .unbounded)
        let (states, stateSink) = AsyncStream<ClaudeRelayState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let relay = ClaudeRelay(api: api, makeRunner: { [weak self] in await self?.makeRunner() },
                                blender: { [weak self] in await self?.blenderServer() },
                                onEvent: { sink.yield(($0, $1, $2)) }, onState: { stateSink.yield($0) },
                                files: { [weak self] in await self?.filesOn ?? false })
        self.relay = relay
        let base = baseURL
        Task { await relay.setAssetBase(base) } // phone turns' image links, when relative
        loops = [
            Task { [weak self] in
                for await (tid, turn, e) in events {
                    guard let self else { break }
                    if let turn { self.ranTurns.insert(turn) }
                    if case .tool(let id, _, _, _, _) = e { self.toolThreads[id] = tid }
                    if case .done = e { self.endFileAsks(threadId: tid, message: "The turn ended before you answered.") }
                    if case .done(_, _, let model?) = e, model != self.info.model { self.info.model = model }
                    self.broadcast(.local(threadId: tid, turnId: turn, e))
                }
            },
            Task { [weak self] in
                for await s in states { self?.relayState = s }
            },
            Task { [weak self] in await self?.listen(api, relay) },
            Task { [weak self] in
                await self?.recheck()
                if self?.isDemo == false { await self?.heartbeatLoop(api, relay) }
            },
        ]
        Task { await refreshStatus() }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.recheck() }
        }
    }

    // MARK: Install and sign-in

    private var environment: [String: String] {
        ClaudeCommand.environment(ProcessInfo.processInfo.environment, executable: executable ?? "/usr/local/bin/claude", home: NSHomeDirectory())
    }

    /// `claude --version` + `claude auth status` (Re-check, app activation, after Install / Sign in).
    func recheck() async {
        if isDemo {
            info = ClaudeCodeInfo(installed: true, signedIn: true, version: "demo", model: info.model ?? "claude-sonnet-demo")
            checkedOnce = true
            return
        }
        guard !checking else { return }
        checking = true
        defer {
            checking = false
            checkedOnce = true
        }
        let exe = ClaudeCodeLocator.find(home: NSHomeDirectory(), path: ProcessInfo.processInfo.environment["PATH"])
        executable = exe
        var next = await ClaudeShell.probe(executable: exe, environment: environment)
        next.model = info.model
        let changed = next.installed != info.installed || next.signedIn != info.signedIn
        info = next
        if changed, let api, configured { _ = try? await api.heartbeat(info) }
    }

    /// Install runs Anthropic's official installer in a Terminal window the owner sees.
    func openInstall() { openTerminal(name: "Install Claude Code.command", script: ClaudeCodeLocator.installScript()) }

    /// Sign in opens Claude's own sign-in (`claude auth login`) in Terminal.
    func openSignIn() {
        guard let exe = executable ?? ClaudeCodeLocator.find(home: NSHomeDirectory(), path: ProcessInfo.processInfo.environment["PATH"]) else {
            openInstall()
            return
        }
        openTerminal(name: "Sign in to Claude.command", script: ClaudeCodeLocator.signInScript(executable: exe))
    }

    private func openTerminal(name: String, script: String) {
        let dir = ClaudeTurnRunner.defaultRoot
        let file = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Terminal", file.path]
            try p.run()
            lastError = nil
        } catch {
            lastError = "Couldn't open Terminal: \(error.localizedDescription)"
            return
        }
        // Watch for the change for a few minutes (the app may stay frontmost).
        pollTask?.cancel()
        let before = info
        pollTask = Task { [weak self] in
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.recheck()
                if self.info.installed != before.installed || self.info.signedIn != before.signedIn, self.info.ready { return }
            }
        }
    }

    // MARK: Server

    func refreshStatus() async {
        guard let api else { return }
        if let s = try? await api.status() { status = s }
    }

    func setApiFallback(_ on: Bool) async {
        guard let api else { return }
        do {
            status = try await api.setApiFallback(on)
            lastError = nil
        } catch {
            lastError = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    private func heartbeatLoop(_ api: any ClaudeAPI, _ relay: ClaudeRelay) async {
        while !Task.isCancelled {
            do {
                let reply = try await api.heartbeat(info)
                await relay.offer(reply.pending)
            } catch {
                if !Task.isCancelled { lastError = "Heartbeat: \((error as? ApiError)?.message ?? error.localizedDescription)" }
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }

    private func listen(_ api: any ClaudeAPI, _ relay: ClaudeRelay) async {
        for await e in api.events() {
            if Task.isCancelled { break }
            switch e {
            case .connected:
                if let turns = try? await api.pendingTurns() { await relay.offer(turns) }
                if let asks = try? await api.pendingPermissions() { for a in asks { await handlePermission(a) } }
                await refreshStatus()
            case .permission(let a):
                await handlePermission(a)
            case .permissionEnd(let id):
                fileAsks.removeAll { $0.id == id }
            case .result(let r):
                resultArrived(r)
            case .turn(let t):
                await relay.offer([t])
            case .stop(let id):
                await relay.stop(turnId: id)
            case .status(let s):
                status = s
            case .event(let tid, let turnId, _):
                // Only this Mac runs Claude Code: its own turns (no turnId) and the phone turns it ran come back from the
                // server too, and the local stream already showed them (the echo can land after the run has ended).
                if relayState.running[tid] != nil || turnId == nil || ranTurns.contains(turnId ?? "") { continue }
            default:
                break
            }
            broadcast(.live(e))
        }
    }

    // MARK: Turns

    private func makeRunner() -> ClaudeTurnRunner? {
        guard let api, info.ready else { return nil }
        if isDemo {
            return ClaudeTurnRunner(api: api, launcher: ClaudeScriptedLauncher(delay: Self.demoLineDelay), tokens: tokens, executable: "claude",
                                    root: FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-demo-claude"), environment: [:])
        }
        guard let exe = executable else { return nil }
        return ClaudeTurnRunner(api: api, tokens: tokens, executable: exe, environment: environment)
    }

    /// Blender's MCP server joins the run while the Blender relay is on (and uv is installed).
    private func blenderServer() -> ClaudeCommand.Blender? {
        guard !isDemo, BlenderRelayService.shared.running,
              let uvx = ClaudeCodeLocator.findUvx(home: NSHomeDirectory(), path: ProcessInfo.processInfo.environment["PATH"]) else { return nil }
        return ClaudeCommand.Blender(uvx: uvx)
    }

    /// Opens (or creates) the thread of a camera or edit session.
    func openThread(contextKind: String, contextId: String) async throws -> ClaudeThreadDetail {
        guard let api else { throw ApiError("offline", "Sign in to your MUSE server first") }
        let t = try await api.thread(contextKind: contextKind, contextId: contextId)
        let d = try await api.threadDetail(t.id)
        await relay?.remember(threadId: t.id, claudeSessionId: d.thread.claudeSessionId, brief: d.thread.brief ?? t.brief)
        return d
    }

    func threadDetail(_ id: String) async throws -> ClaudeThreadDetail {
        guard let api else { throw ApiError("offline", "Sign in to your MUSE server first") }
        return try await api.threadDetail(id)
    }

    // MARK: Chat sessions (WS18)

    /// A chat picked from the list (or remembered): its messages, and its Claude Code session and brief for the next turn.
    func loadThread(_ id: String) async throws -> ClaudeThreadDetail {
        guard let api else { throw ApiError("offline", "Sign in to your MUSE server first") }
        let d = try await api.threadDetail(id)
        await relay?.remember(threadId: d.thread.id, claudeSessionId: d.thread.claudeSessionId, brief: d.thread.brief)
        return d
    }

    /// The place's chats, newest first (`not_found` on an older server: one chat per place).
    func threads(key: String) async throws -> [ClaudeThread] {
        guard let api else { throw ApiError("offline", "Sign in to your MUSE server first") }
        return try await api.threads(key: key)
    }

    /// A new chat about the same context, opened.
    func newThread(contextKind: String, contextId: String) async throws -> ClaudeThreadDetail {
        guard let api else { throw ApiError("offline", "Sign in to your MUSE server first") }
        let t = try await api.newThread(contextKind: contextKind, contextId: contextId)
        return try await loadThread(t.id)
    }

    func renameThread(_ id: String, title: String) async throws -> ClaudeThread {
        guard let api else { throw ApiError("offline", "Sign in to your MUSE server first") }
        return try await api.renameThread(id, title: title)
    }

    func deleteThread(_ id: String) async throws {
        guard let api else { throw ApiError("offline", "Sign in to your MUSE server first") }
        if relayState.running[id] != nil { await relay?.stop(threadId: id) }
        try await api.deleteThread(id)
    }

    /// A turn typed on this Mac (queued behind the thread's running turn).
    func send(threadId: String, text: String, files: [ClaudeAttachmentFile] = []) {
        guard let relay else { return }
        Task { await relay.submit(threadId: threadId, text: text, files: files) }
    }

    /// Stop: this Mac's run of the thread, or (a turn running elsewhere) ask the server to stop it.
    func stop(threadId: String, remoteTurnId: String?) {
        endFileAsks(threadId: threadId, message: "Stopped.")
        if relayState.running[threadId] != nil {
            Task { await relay?.stop(threadId: threadId) }
        } else if let id = remoteTurnId, let api {
            Task { try? await api.stopTurn(id) }
        }
    }

    /// Step 6b: the person's default model and a chat's own, for the next Claude Code run (--model).
    func relayDefaultModel(_ m: String?) async { await relay?.setDefaultModel(m) }
    func relayChatModel(threadId: String, _ m: String?) async { await relay?.setModel(threadId: threadId, m) }

    func isRunning(threadId: String) -> Bool { relayState.running[threadId] != nil }
    func isAnsweringPhone(threadId: String) -> Bool { relayState.running[threadId]?.fromPhone == true }
    var answeringFromPhone: Bool { relayState.answeringFromPhone }

    /// The studio API key fallback (camera threads only): ChatEvents like the camera chat.
    func apiTurn(threadId: String, text: String) -> AsyncThrowingStream<ChatEvent, Error>? { api?.apiTurn(threadId: threadId, text: text) }

    /// A server link ("/uploads/…") made absolute; data: and http(s) URLs as they are.
    func resolve(_ url: String) -> String {
        guard url.hasPrefix("/"), let base = baseURL else { return url }
        var s = base.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s + url
    }

    // MARK: Files on this Mac (ask every time)

    /// One approval card: Claude Code's question, the chat it belongs to and what the card says.
    struct FileAsk: Identifiable, Hashable {
        let ask: ClaudePermissionAsk
        let threadId: String?
        let card: ClaudeFileCard
        var id: String { ask.id }
    }

    @Published private(set) var fileSettings = ClaudeFileSettings()
    @Published private(set) var fileAsks: [FileAsk] = []
    private var personId: String?
    /// Claude Code's tool_use id → the chat whose run made it (the question names the tool_use id).
    private var toolThreads: [String: String] = [:]

    var filesOn: Bool { fileSettings.mode == .ask }

    /// The signed-in person: their own file settings on this Mac.
    func setPerson(_ id: String?) {
        guard id != personId else { return }
        personId = id
        fileAsks = []
        guard let id, let d = UserDefaults.standard.data(forKey: ClaudeFileSettings.key(userId: id)),
              let s = try? JSONDecoder().decode(ClaudeFileSettings.self, from: d) else {
            fileSettings = ClaudeFileSettings()
            return
        }
        fileSettings = s
    }

    private func saveFileSettings() {
        guard let personId, let d = try? JSONEncoder().encode(fileSettings) else { return }
        UserDefaults.standard.set(d, forKey: ClaudeFileSettings.key(userId: personId))
    }

    func setFileMode(_ m: ClaudeFileMode) {
        fileSettings.mode = m
        saveFileSettings()
        if m == .off { for a in fileAsks { answerFile(a.id, .deny) } }
    }

    func removeAllowedFolder(_ id: String) {
        fileSettings.remove(id)
        saveFileSettings()
    }

    /// The cards of one chat (a question this Mac can't place goes to the chat running here).
    func fileAsks(threadId: String) -> [FileAsk] { fileAsks.filter { $0.threadId == threadId } }

    private func handlePermission(_ a: ClaudePermissionAsk) async {
        guard let api, !fileAsks.contains(where: { $0.id == a.id }) else { return }
        // Only the Mac running that turn answers (each of the person's Macs hears the question).
        let tid = a.toolUseId.flatMap { toolThreads[$0] } ?? relayState.running.first { !$0.value.fromPhone }?.key
        guard let tid else {
            // A phone turn running here has nobody at the Mac to answer: say so at once instead of waiting.
            if relayState.running.values.contains(where: { $0.fromPhone }) {
                try? await api.answerPermission(a.id, allow: false, message: "Files on the Mac need you at the Mac: ask again from MUSE on your Mac.")
            }
            return
        }
        let cwd = ClaudeTurnRunner.defaultRoot.appendingPathComponent(tid, isDirectory: true).path
        switch ClaudeFilePolicy.verdict(a, mode: fileSettings.mode, folders: fileSettings.folders(chatId: tid), cwd: cwd, home: NSHomeDirectory()) {
        case .allow where a.toolName == "Upload":
            await uploadLocal(a, cwd: cwd)
        case .allow:
            try? await api.answerPermission(a.id, allow: true, message: nil)
        case .deny(let why):
            try? await api.answerPermission(a.id, allow: false, message: why)
        case .ask(let card):
            fileAsks.append(FileAsk(ask: a, threadId: tid, card: card))
        }
    }

    /// The person's answer on a card. "Always" saves the folder for this chat (Settings → Claude lists it).
    func answerFile(_ id: String, _ answer: ClaudePermissionAnswer, chatTitle: String? = nil) {
        guard let a = fileAsks.first(where: { $0.id == id }) else { return }
        fileAsks.removeAll { $0.id == id }
        if case .alwaysFolder(let folder) = answer, let tid = a.threadId, a.card.folder != nil {
            fileSettings.allow(folder, chatId: tid, chatTitle: chatTitle)
            saveFileSettings()
            // Other questions of this chat in the same folder go through too.
            for other in fileAsks where other.threadId == tid {
                if let f = other.card.folder, ClaudeFilePolicy.inside(f, folder) || ClaudeFilePolicy.inside(other.card.detail, folder) { answerFile(other.id, .allowOnce) }
            }
        }
        let allow: Bool
        if case .deny = answer { allow = false } else { allow = true }
        guard let api else { return }
        if allow, a.ask.toolName == "Upload" {
            let cwd = ClaudeTurnRunner.defaultRoot.appendingPathComponent(a.threadId ?? "", isDirectory: true).path
            Task { await uploadLocal(a.ask, cwd: cwd) }
            return
        }
        Task { try? await api.answerPermission(id, allow: allow, message: allow ? nil : "The person said no.") }
    }

    /// upload_local_file, after the yes: the file goes up the chat's way (an image: presign, PUT, confirm, so the server
    /// strips its metadata; a video as a clip with its length and size), and the upload goes back to Claude.
    private func uploadLocal(_ a: ClaudePermissionAsk, cwd: String) async {
        guard let api else { return }
        var raw = ""
        if case .object(let o)? = a.input, case .string(let p)? = o["file_path"] { raw = p }
        let path = ClaudeFilePolicy.resolve(raw, cwd: cwd, home: NSHomeDirectory())
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        func fail(_ why: String) async { try? await api.answerPermission(a.id, allow: false, message: why) }
        guard !ClaudeFilePolicy.isSecret(path) else { return await fail(ClaudeFilePolicy.credentialRefusal) }
        guard let type = ClaudeFilePolicy.uploadType(path) else { return await fail(ClaudeFilePolicy.uploadRefusal) }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
        guard let size else { return await fail("There's no file at \(path).") }
        do {
            let att: ClaudeAttachment
            if type.video {
                guard size <= 500 * 1024 * 1024 else { return await fail(ClaudeFilePolicy.uploadRefusal) }
                guard let up = api as? any ClaudeVideoUploading, let info = await ChatVideoProbe.read(url) else { return await fail("That video can't be read.") }
                att = try await up.uploadClaudeVideo(url, meta: info.meta(name: name), contentType: type.mime, progress: nil)
            } else {
                guard size <= SuiteClaudeAttachments.maxBytes else { return await fail(ClaudeFilePolicy.uploadRefusal) }
                guard let up = api as? any ClaudeImageUploading else { return await fail("This server can't take images from Claude yet.") }
                att = try await up.uploadClaudeImage(name: name, data: try Data(contentsOf: url), mime: type.mime)
            }
            try await api.finishUpload(a.id, ClaudeLocalUpload(uploadId: att.uploadId, kind: type.video ? "clip" : "image", url: att.url, name: name))
        } catch {
            await fail("Couldn't upload \(name): \((error as? ApiError)?.message ?? error.localizedDescription)")
        }
    }

    /// A stopped or finished turn: its open cards end as a no (nothing is done without an answer).
    private func endFileAsks(threadId: String, message: String) {
        let mine = fileAsks.filter { $0.threadId == threadId }
        guard !mine.isEmpty else { return }
        fileAsks.removeAll { $0.threadId == threadId }
        guard let api else { return }
        for a in mine { Task { try? await api.answerPermission(a.id, allow: false, message: message) } }
    }

    // MARK: Results arrive in the chat

    /// Results that came while the Claude panel was closed (the dot on the Claude button).
    @Published private(set) var unseenResults = 0
    private var results = ClaudeResultBatcher()
    private var resultTimer: Task<Void, Never>?

    func clearUnseenResults() { unseenResults = 0 }

    func setResultMode(_ m: ClaudeResultMode) {
        fileSettings.results = m
        saveFileSettings()
    }

    /// Something started from one of this person's chats finished. Only the Mac that runs this person's Claude Code acts
    /// (every Mac of theirs hears it); with "Just notify me", or Claude Code not ready, it only tells them.
    private func resultArrived(_ r: ClaudeJobResult) {
        if ClaudeChatLink.current == nil { unseenResults += 1 } // the panel is closed
        let look = fileSettings.resultMode == .look && info.ready && relay != nil
        if !look {
            Notifier.shared.post(title: r.failed ? "Didn't finish" : "Result arrived", body: r.line)
            return
        }
        results.add(r, now: Date().timeIntervalSince1970)
        guard resultTimer == nil else { return }
        resultTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                for b in self.results.due(now: Date().timeIntervalSince1970) { self.lookAt(b.chatId, b.results) }
                if self.results.isEmpty { self.resultTimer = nil; return }
            }
        }
    }

    /// One follow-up turn per chat and batch: queued behind a turn that is running; it never takes the person's focus.
    private func lookAt(_ chatId: String, _ batch: [ClaudeJobResult]) {
        guard let relay else { return }
        let text = ClaudeResultBatcher.message(batch)
        Task { await relay.submit(threadId: chatId, text: text) }
        let first = batch[0]
        Notifier.shared.post(title: batch.allSatisfy(\.failed) ? "Claude is looking at what went wrong" : "Claude looked at your \(first.isPhoto ? "photos" : first.kind)",
                             body: batch.map(\.line).joined(separator: " · "))
    }

    // MARK: Feed

    func feed() -> AsyncStream<Feed> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { cont in
            let id = UUID()
            listeners[id] = cont
            cont.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[id] = nil } }
        }
    }

    private func broadcast(_ f: Feed) {
        for l in listeners.values { l.yield(f) }
    }
}
