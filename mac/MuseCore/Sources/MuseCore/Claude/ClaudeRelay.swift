import Foundation

/// A turn waiting to run on this Mac: typed here, or a phone turn from the server.
public struct ClaudeJob: Hashable, Sendable, Identifiable {
    /// The turn id for phone turns; a local id for the Mac's own.
    public var id: String
    public var threadId: String
    public var text: String
    /// Set for phone turns (claimed before they run).
    public var turnId: String?

    public init(id: String, threadId: String, text: String, turnId: String? = nil) {
        self.id = id
        self.threadId = threadId
        self.text = text
        self.turnId = turnId
    }

    public var fromPhone: Bool { turnId != nil }
}

/// One turn at a time per thread; the rest wait in order. Pure bookkeeping (no I/O).
public struct ClaudeTurnQueue: Hashable, Sendable {
    public private(set) var running: [String: ClaudeJob] = [:]
    public private(set) var waiting: [String: [ClaudeJob]] = [:]
    /// Phone turns already seen (a turn arrives by live event, heartbeat and catch-up).
    private var seen: Set<String> = []

    public init() {}

    /// Adds a job; false for a phone turn already seen.
    @discardableResult
    public mutating func enqueue(_ job: ClaudeJob) -> Bool {
        if let t = job.turnId {
            guard !seen.contains(t) else { return false }
            seen.insert(t)
        }
        waiting[job.threadId, default: []].append(job)
        return true
    }

    /// The next job of a thread that isn't running anything; it is now running.
    public mutating func next(_ threadId: String) -> ClaudeJob? {
        guard running[threadId] == nil, var list = waiting[threadId], !list.isEmpty else { return nil }
        let j = list.removeFirst()
        waiting[threadId] = list.isEmpty ? nil : list
        running[threadId] = j
        return j
    }

    public mutating func finish(_ threadId: String) { running[threadId] = nil }

    /// Drops a waiting phone turn (stopped or expired before it ran). Returns whether one was dropped.
    @discardableResult
    public mutating func drop(turnId: String) -> Bool {
        for (tid, list) in waiting {
            if let i = list.firstIndex(where: { $0.turnId == turnId }) {
                var l = list
                l.remove(at: i)
                waiting[tid] = l.isEmpty ? nil : l
                return true
            }
        }
        return false
    }

    public func runningThread(turnId: String) -> String? { running.first { $0.value.turnId == turnId }?.key }
    public var threadsWithWork: [String] { Array(Set(waiting.keys).subtracting(running.keys)).sorted() }
    public func queuedCount(_ threadId: String) -> Int { waiting[threadId]?.count ?? 0 }
    public var isIdle: Bool { running.isEmpty && waiting.isEmpty }
}

/// What the UI shows: which threads are answering, from where, and how many turns wait.
public struct ClaudeRelayState: Hashable, Sendable {
    public var running: [String: ClaudeJob] = [:]
    public var queued: [String: Int] = [:]
    public init(running: [String: ClaudeJob] = [:], queued: [String: Int] = [:]) {
        self.running = running
        self.queued = queued
    }
    public var answeringFromPhone: Bool { running.values.contains { $0.fromPhone } }
}

/// The Mac side of Claude chat: takes local and phone turns, claims phone turns, runs them one at a time per thread through
/// ClaudeTurnRunner, and routes Stop. The app wraps it with the heartbeat and the live event stream.
public actor ClaudeRelay {
    public typealias RunnerFactory = @Sendable () async -> ClaudeTurnRunner?

    public let api: any ClaudeAPI
    private let makeRunner: RunnerFactory
    private let blender: @Sendable () async -> ClaudeCommand.Blender?
    private let onEvent: @Sendable (String, String?, ClaudeEvent) -> Void
    private let onState: @Sendable (ClaudeRelayState) -> Void

    private var queue = ClaudeTurnQueue()
    private var runners: [String: ClaudeTurnRunner] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    /// Claude Code session per thread (for --resume).
    private var sessions: [String: String] = [:]
    private var counter = 0
    private var closed = false
    /// Stop pressed while the turn was still being claimed or set up.
    private var stopPending: Set<String> = []

    public init(api: any ClaudeAPI, makeRunner: @escaping RunnerFactory, blender: @escaping @Sendable () async -> ClaudeCommand.Blender? = { nil },
                onEvent: @escaping @Sendable (String, String?, ClaudeEvent) -> Void, onState: @escaping @Sendable (ClaudeRelayState) -> Void = { _ in }) {
        self.api = api
        self.makeRunner = makeRunner
        self.blender = blender
        self.onEvent = onEvent
        self.onState = onState
    }

    public var state: ClaudeRelayState {
        var q: [String: Int] = [:]
        for (k, v) in queue.waiting { q[k] = v.count }
        return ClaudeRelayState(running: queue.running, queued: q)
    }

    /// The thread's known Claude Code session (from its detail); saves a lookup when the turn runs.
    public func remember(threadId: String, claudeSessionId: String?) {
        if let s = claudeSessionId, !s.isEmpty { sessions[threadId] = s }
    }

    /// A turn typed on this Mac. Returns its local id.
    @discardableResult
    public func submit(threadId: String, text: String) -> String {
        counter += 1
        let id = "local_\(counter)"
        queue.enqueue(ClaudeJob(id: id, threadId: threadId, text: text))
        publish()
        pump()
        return id
    }

    /// Phone turns (live `{op: "turn"}`, heartbeat `pending`, GET /v1/claude/turns). Only queued ones are taken.
    public func offer(_ turns: [ClaudeTurn]) {
        guard !closed else { return }
        var added = false
        for t in turns where t.state == "queued" && t.from != "mac" {
            if queue.enqueue(ClaudeJob(id: t.id, threadId: t.threadId, text: t.text, turnId: t.id)) { added = true }
        }
        if added {
            publish()
            pump()
        }
    }

    /// Stop on this Mac (the thread's running turn; waiting local turns of the thread are dropped too).
    public func stop(threadId: String) {
        if let r = runners[threadId] { r.stop() } else if queue.running[threadId] != nil { stopPending.insert(threadId) }
    }

    /// `claude` `{op: "stop", turnId}` from the phone.
    public func stop(turnId: String) {
        if let tid = queue.runningThread(turnId: turnId) {
            stop(threadId: tid)
        } else if queue.drop(turnId: turnId) {
            publish()
        }
    }

    /// Signing out: stop everything.
    public func close() {
        closed = true
        for r in runners.values { r.stop() }
        for w in workers.values { w.cancel() }
    }

    public func isRunning(threadId: String) -> Bool { queue.running[threadId] != nil }

    private func publish() { onState(state) }

    private func pump() {
        guard !closed else { return }
        for tid in queue.threadsWithWork where workers[tid] == nil {
            guard let job = queue.next(tid) else { continue }
            publish()
            workers[tid] = Task { [weak self] in
                await self?.execute(job)
                await self?.finished(tid)
            }
        }
    }

    private func finished(_ threadId: String) {
        queue.finish(threadId)
        workers[threadId] = nil
        runners[threadId] = nil
        stopPending.remove(threadId)
        publish()
        pump()
    }

    private func execute(_ job: ClaudeJob) async {
        let tid = job.threadId
        guard let runner = await makeRunner() else {
            // Not ready: a phone turn stays queued on the server (it times out there); a local one fails here.
            if !job.fromPhone { onEvent(tid, nil, .done(ok: false, error: "Claude Code isn't ready on this Mac", model: nil)) }
            return
        }
        if let turnId = job.turnId {
            do {
                let t = try await api.claim(turnId: turnId)
                if t.state != "running" && t.state != "queued" { return }
            } catch {
                return // already_claimed / turn_expired / offline: not ours to run.
            }
        }
        runners[tid] = runner
        if stopPending.remove(tid) != nil { runner.stop() }
        if sessions[tid] == nil, let d = try? await api.threadDetail(tid), let s = d.thread.claudeSessionId, !s.isEmpty { sessions[tid] = s }
        let req = ClaudeRunRequest(threadId: tid, turnId: job.turnId, text: job.text, resume: sessions[tid], blender: await blender())
        let onEvent = self.onEvent
        let turnId = job.turnId
        let outcome = await runner.run(req) { e in onEvent(tid, turnId, e) }
        if let s = outcome.sessionId { sessions[tid] = s }
    }
}
