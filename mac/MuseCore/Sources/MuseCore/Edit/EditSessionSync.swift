import Foundation

// Edit sessions (workstream 3, plans/video-editor.md "Edit sessions and edit ops"): keeps the editor in step with the server's
// session that the owner's apps and Claude share. Pure logic over `MuseAPI` (no timers, no UI), so it runs in tests on Linux:
//   - open → the session's revision and project;
//   - local changes are pushed (the app debounces ~0.5 s, then calls `flush`) as `diff(lastSynced, current)` with a label;
//   - `409 stale_revision` → fetch the session, rebase the unsent local change on top of it (re-diff it against the server's
//     project; if it no longer applies, the server's wins) and push again;
//   - remote `patch` events apply when their `baseRevision` is this revision (else the session is fetched again);
//   - the history (newest first) carries `byClaude`; undo of any entry is the server's `undo`.
// Every method that can change what the editor shows returns the project to show.

@MainActor
public final class EditSessionSync {
    public typealias Project = EditV2.Project

    /// What the editor does after an event or a call.
    public enum Update: Equatable, Sendable {
        /// Show this project (a remote change, a rebase, or the server's version). `entry` is the change that landed, if known.
        case project(Project, entry: EditHistoryEntry?)
        /// Only the history changed (a note: Claude looked at something).
        case history(EditHistoryEntry)
        /// A paid helper Claude asked for changed (`waiting` = ask the owner).
        case pending(EditPending)
        /// Claude wants the exact frame at `t` (timeline seconds), `width` pixels wide.
        case frameRequest(requestId: String, t: Double, width: Int)
        /// Claude asked this app to save a version or export.
        case appRequest(EditAppRequest)
        /// The session was closed (the next open starts a new one).
        case closed
    }

    public let api: any MuseAPI
    public let device: String
    public let sessionId: String
    public let takeId: String
    public private(set) var revision: Int
    /// The server's project as JSON (remote patches apply to it).
    public private(set) var serverDoc: JSONValue
    /// The server's project at `revision`, as the editor reads it.
    public private(set) var synced: Project
    /// The editor's change not on the server yet (nil = in step).
    public private(set) var local: Project?
    public private(set) var localLabel: String?
    public private(set) var history: [EditHistoryEntry]
    /// Paid helpers waiting for the owner or running.
    public private(set) var pending: [EditPending]
    public private(set) var isClosed = false
    /// Suite looks the project may use (`palette:<id>`), for checking a rebased change.
    public var paletteIds: Set<String>
    public static let historyKept = 60

    private var pushing = false

    public init(api: any MuseAPI, device: String, session: EditSession, paletteIds: Set<String> = []) throws {
        self.api = api
        self.device = device
        self.paletteIds = paletteIds
        sessionId = session.id
        takeId = session.takeId
        revision = session.revision
        serverDoc = session.project
        synced = try Self.read(session.project)
        history = Array((session.history ?? []).prefix(Self.historyKept))
        pending = session.pending.filter { $0.status == "waiting" || $0.status == "running" }
        isClosed = session.status == "closed"
    }

    /// Opens (or creates) the session for a take. `project` is what the editor starts from when the take has no session yet.
    public static func open(api: any MuseAPI, takeId: String, project: Project?, device: String, paletteIds: Set<String> = []) async throws -> EditSessionSync {
        let s = try await api.openEditSession(EditSessionOpenRequest(takeId: takeId, project: project, device: device))
        return try EditSessionSync(api: api, device: device, session: s, paletteIds: paletteIds)
    }

    /// One Claude: joins a session that already exists (Claude opened it, e.g. a new blank project) instead of opening a
    /// take's: a blank take always makes a new session, so opening by take would miss Claude's.
    public static func attach(api: any MuseAPI, sessionId: String, device: String, paletteIds: Set<String> = []) async throws -> EditSessionSync {
        let s = try await api.editSession(id: sessionId)
        return try EditSessionSync(api: api, device: device, session: s, paletteIds: paletteIds)
    }

    /// The project the editor should show: the unsent change, else the server's.
    public var current: Project { local ?? synced }
    public var hasUnsent: Bool { local != nil }
    public var author: String { "app:\(device)" }

    static func read(_ doc: JSONValue) throws -> Project {
        do { return try JSONPatch.decode(Project.self, doc) } catch { throw ApiError("bad_response", "The edit session's project couldn't be read") }
    }

    // MARK: Local changes

    /// The editor changed the project (call on every change; push with `flush` after a short pause).
    public func localChanged(_ p: Project, label: String? = nil) {
        if p == synced { local = nil; localLabel = nil; return }
        let l = label ?? Self.label(from: local ?? synced, to: p)
        localLabel = localLabel.map { $0 == l ? $0 : Self.joined($0, l) } ?? l
        local = p
    }

    static func joined(_ a: String, _ b: String) -> String {
        let parts = a.components(separatedBy: " · ")
        if parts.contains(b) { return a }
        return parts.count >= 3 ? a : "\(a) · \(b)"
    }

    /// Pushes the unsent change. Returns what to show when a conflict changed it (rebased, or the server's when it no longer
    /// applies); nil when the editor already shows the right thing. Errors other than conflicts are thrown (the change stays unsent).
    @discardableResult
    public func flush() async throws -> Update? {
        guard !pushing, !isClosed else { return nil }
        pushing = true
        defer { pushing = false }
        var shown: Update?
        for _ in 0..<3 {
            guard let target = local else { return shown }
            let base = revision
            let patch = JSONPatch.diff(try JSONPatch.encode(synced), try JSONPatch.encode(target))
            if patch.isEmpty { local = nil; localLabel = nil; return shown }
            let label = localLabel ?? "Edit"
            do {
                let r = try await api.pushEditPatch(sessionId: sessionId, EditPatchRequest(baseRevision: base, patch: patch, label: label, device: device))
                if revision == base {
                    serverDoc = try JSONPatch.apply(serverDoc, patch)
                    synced = try Self.read(serverDoc)
                    revision = r.revision
                    if let e = r.entry { remember(e) }
                    if local == target { local = nil; localLabel = nil }
                } else {
                    // Something arrived while the change was on its way: take the server's state (which has it) exactly.
                    if let e = r.entry { remember(e) }
                    if local == target { local = nil; localLabel = nil }
                    if let u = try await refresh() { shown = u }
                }
                return shown
            } catch let e as ApiError where e.code == "stale_revision" {
                if let u = try await refresh() { shown = u }
            }
        }
        return shown
    }

    // MARK: Server state

    /// Fetches the session and adopts it (rebasing the unsent change). Returns what to show when it differs.
    @discardableResult
    public func refresh() async throws -> Update? {
        let s = try await api.editSession(id: sessionId)
        if let h = s.history { history = Array(h.prefix(Self.historyKept)) }
        pending = s.pending.filter { $0.status == "waiting" || $0.status == "running" }
        if s.status == "closed" { isClosed = true }
        return try adopt(s.project, revision: s.revision, entry: nil, force: false)
    }

    /// Takes the server's project at `revision`; the unsent change is re-applied on top when it still fits.
    private func adopt(_ doc: JSONValue, revision rev: Int, entry: EditHistoryEntry?, force: Bool) throws -> Update? {
        let before = current
        let oldBase = synced
        serverDoc = doc
        synced = try Self.read(doc)
        revision = rev
        if let l = local {
            if let r = rebase(l, from: oldBase, onto: synced), r != synced { local = r } else { local = nil; localLabel = nil }
        }
        let now = current
        return now == before && !force ? nil : .project(now, entry: entry)
    }

    /// The change from `base` to `change`, applied on top of `onto`; nil when it doesn't fit (or breaks a rule).
    public func rebase(_ change: Project, from base: Project, onto: Project) -> Project? {
        guard let patch = try? JSONPatch.diff(JSONPatch.encode(base), JSONPatch.encode(change)),
              let doc = try? JSONPatch.apply(JSONPatch.encode(onto), patch),
              let p = try? Self.read(doc), EditV2.problem(p, paletteIds: paletteIds) == nil else { return nil }
        return p
    }

    private func remember(_ e: EditHistoryEntry) {
        if let i = history.firstIndex(where: { $0.id == e.id }) { history[i] = e } else {
            history.insert(e, at: 0)
            history.sort { $0.id > $1.id }
        }
        if let u = e.undoes, let i = history.firstIndex(where: { $0.id == u }) { history[i].undone = true }
        if history.count > Self.historyKept { history.removeLast(history.count - Self.historyKept) }
    }

    // MARK: Events

    /// An `edit` event. Returns what the editor should do, or nil when it isn't for this session or changes nothing.
    public func handle(_ e: EditSessionEvent) async -> Update? {
        guard e.sessionId == sessionId else { return nil }
        switch e.op {
        case "patch":
            guard let rev = e.revision, let patch = e.patch else { return nil }
            if let entry = e.entry { remember(entry) }
            // Our own change on its way back: `flush` takes it from the reply.
            if pushing, e.entry?.author == author { return nil }
            if rev <= revision { return nil }
            if e.baseRevision == revision, let doc = try? JSONPatch.apply(serverDoc, patch),
               let u = try? adopt(doc, revision: rev, entry: e.entry, force: true) {
                return u
            }
            // Missed a change (or the patch didn't fit): fetch the session.
            guard let u = try? await refresh() else { return nil }
            if case .project(let p, _) = u { return .project(p, entry: e.entry) }
            return u
        case "log":
            guard let entry = e.entry else { return nil }
            remember(entry)
            return .history(entry)
        case "pending":
            guard let p = e.pending else { return nil }
            pending.removeAll { $0.id == p.id }
            if p.status == "waiting" || p.status == "running" { pending.append(p) }
            return .pending(p)
        case "frame_request":
            guard let rid = e.requestId, let t = e.t, e.device == nil || e.device == device else { return nil }
            return .frameRequest(requestId: rid, t: t, width: e.width ?? 540)
        case "app_request":
            guard let r = e.request, r.device == device, r.status == "sent" else { return nil }
            return .appRequest(r)
        case "closed":
            isClosed = true
            return .closed
        default:
            return nil
        }
    }

    // MARK: Claude's side

    /// Undoes one change on the server (any author; Claude's are badged). Returns what to show.
    @discardableResult
    public func undo(entryId: Int) async throws -> Update? {
        let r = try await api.undoEditChange(sessionId: sessionId, entryId: entryId, device: device)
        if let i = history.firstIndex(where: { $0.id == entryId }) { history[i].undone = true }
        if let e = r.entry { remember(e) }
        guard r.revision > revision else { return nil } // the event already brought it
        guard let u = try await refresh() else { return nil }
        if case .project(let p, _) = u { return .project(p, entry: r.entry) }
        return u
    }

    /// The owner's answer to a paid helper Claude asked for.
    @discardableResult
    public func answer(pendingId: String, approve: Bool) async throws -> EditPending {
        let p = try await api.answerEditPending(sessionId: sessionId, pendingId: pendingId, approve: approve)
        pending.removeAll { $0.id == p.id }
        if p.status == "waiting" || p.status == "running" { pending.append(p) }
        return p
    }

    /// Paid helpers still waiting for the owner.
    public var waiting: [EditPending] { pending.filter(\.isWaiting) }
    /// Claude's changes, newest first (for the Claude panel).
    public var claudeEntries: [EditHistoryEntry] { history.filter(\.byClaude) }

    /// "I have the edit open" (every 30 s): Claude's frames and save/export come to this app.
    public func announce(label: String, platform: String = "mac", canRender: Bool = true, preview: EditPreview? = nil) async throws {
        try await api.announceEditPresence(sessionId: sessionId, EditPresence(device: device, label: label, platform: platform, canRender: canRender,
                                                                              preview: preview))
    }

    public func leave() async {
        try? await api.leaveEditSession(sessionId: sessionId, device: device)
    }

    // MARK: This device's unsent changes (drafts)

    /// The change not on the server yet, to keep on this device (so closing, a crash or being offline never loses it).
    public var draft: EditSessionDraft? {
        local.map { EditSessionDraft(takeId: takeId, sessionId: sessionId, baseRevision: revision, project: $0, base: synced, label: localLabel,
                                     savedAt: Date().timeIntervalSince1970) }
    }

    /// A draft this device kept for the take differs from the session's latest: ask "Keep this device's changes / Use the latest".
    public func conflicts(with d: EditSessionDraft?) -> Bool {
        guard let d, d.takeId == takeId else { return false }
        return d.project != synced
    }

    /// "Keep this device's changes": the draft goes on top of the latest revision as one change. This device's changes are
    /// re-applied on the latest (others' changes since stay); when they no longer fit, the device's whole project wins.
    /// Returns the project to show.
    @discardableResult
    public func keep(_ d: EditSessionDraft) async throws -> Update {
        let mine = d.base.flatMap { rebase(d.project, from: $0, onto: synced) } ?? d.project
        localChanged(mine, label: d.label ?? "Changes from this device")
        let u = try await flush()
        return u ?? .project(current, entry: history.first)
    }

    // MARK: Labels

    /// A short label for a local change ("Split", "Look", "Captions"…), from what changed.
    public static func label(from a: Project, to b: Project) -> String {
        if a.canvas.width != b.canvas.width || a.canvas.height != b.canvas.height { return "Shape" }
        let ma = a.mainClips, mb = b.mainClips
        if mb.count > ma.count { return ma.count + 1 == mb.count && a.assets.count == b.assets.count ? "Split" : "Added a clip" }
        if mb.count < ma.count { return "Deleted a clip" }
        let looks = { (p: Project) in p.tracks.flatMap { $0.items.compactMap { $0.videoClip?.look ?? $0.imageItem?.look } } }
        if looks(a) != looks(b) { return "Look" }
        var kinds: [EditV2.TrackKind] = []
        for t in b.tracks where a.track(t.id) != t { kinds.append(t.kind) }
        for t in a.tracks where b.track(t.id) == nil { kinds.append(t.kind) }
        switch Set(kinds).count == 1 ? kinds.first : nil {
        case .main?: return "Timeline"
        case .caption?: return "Captions"
        case .text?: return "Text"
        case .music?: return "Music"
        case .voice?: return "Voice-over"
        case .sfx?: return "Sound effects"
        case .video?, .image?: return "Overlay"
        case .adjust?: return "Adjustment"
        case nil: return "Edit"
        }
    }
}
