import Foundation

// Edit sessions (workstream 3) in demo mode and tests: the server's rules in memory — one open session per take, revision checks
// (`stale_revision`), every change stored with its inverse so any change can be undone (`already_undone`, `cannot_undo`),
// owner only, `edit` events to the app. The `fakeClaude…` helpers play Claude's side for tests (a change, a paid helper waiting
// for the owner, a frame or save/export request).

/// One stored change (the server's edit_ops row).
struct FakeEditChange: Sendable {
    var entry: EditHistoryEntry
    var patch: [EditPatchOp]
    var inverse: [EditPatchOp]
}

/// One session (the server's edit_sessions row plus what the server keeps in memory).
public struct FakeEditSessionRecord: Sendable {
    var session: EditSession
    var changes: [FakeEditChange] = []
    var presence: [String: EditPresence] = [:]
    /// Answers the app gave: frame request id → upload id; save/export request id → its answer.
    public internal(set) var frameAnswers: [String: String] = [:]
    public internal(set) var requestAnswers: [String: EditAppRequestAnswer] = [:]
    public var revision: Int { session.revision }
    public var project: JSONValue { session.project }
    public var history: [EditHistoryEntry] { changes.reversed().map(\.entry) }
    public var pending: [EditPending] { session.pending }
}

extension FakeMuseAPI {
    /// The fake has no suite-look files: any `palette:<id>` the project names is taken as shipped.
    static func palettes(_ p: EditV2.Project) -> Set<String> {
        let luts = p.tracks.flatMap(\.items).compactMap { $0.videoClip?.look?.lut ?? $0.imageItem?.look?.lut }
        return Set(luts.filter { $0.hasPrefix("palette:") }.map { String($0.dropFirst(8)) })
    }

    private func editOwner() throws { guard isOwner else { throw ApiError("owner_only", "Editing with Claude is for the studio owner") } }

    private func record(_ id: String) throws -> FakeEditSessionRecord {
        try editOwner()
        guard let r = editSessions[id] else { throw ApiError("not_found", "Edit session not found") }
        return r
    }

    private func view(_ r: FakeEditSessionRecord, history: Bool = true) -> EditSession {
        var s = r.session
        s.pending = s.pending.filter { $0.status == "waiting" || $0.status == "running" }
        s.online = Array(r.presence.values).sorted { $0.device < $1.device }
        s.history = history ? Array(r.history.prefix(60)) : nil
        if let p = try? JSONPatch.decode(EditV2.Project.self, s.project) { s.durationSec = EditV2.durationSec(p) }
        return s
    }

    private func emitEdit(_ e: EditSessionEvent) {
        var ev = ApiEvent(type: "edit")
        ev.op = e.op
        ev.edit = e
        hub.emit(ev)
    }

    private static func author(_ device: String?) -> String { device.map { $0.isEmpty ? "app" : "app:\($0.prefix(40))" } ?? "app" }

    /// Validates a project the way the server does (the model's rules; the session's take).
    private func checked(_ doc: JSONValue, takeId: String) throws -> EditV2.Project {
        let p: EditV2.Project
        do { p = try JSONPatch.decode(EditV2.Project.self, doc) } catch { throw ApiError("bad_request", "project: not an edit project") }
        // A blank project still being built may be empty (the server's validate draft mode).
        if !(p.isBlank && p.mainClips.isEmpty), let problem = EditV2.problem(p, paletteIds: Self.palettes(p)) { throw ApiError("bad_request", "project.\(problem.description)") }
        if p.sourceTakeId != takeId { throw ApiError("bad_request", "project.sourceTakeId: must be the session's take") }
        return p
    }

    /// Stores a change (patch + inverse), bumps the revision and tells the apps.
    @discardableResult
    private func commit(_ id: String, next: JSONValue, author: String, kind: String, label: String, undoes: Int? = nil) -> EditHistoryEntry? {
        guard var r = editSessions[id] else { return nil }
        let patch = JSONPatch.diff(r.session.project, next), inverse = JSONPatch.diff(next, r.session.project)
        if patch.isEmpty && kind != "tool" { return nil }
        let base = r.session.revision
        let rev = base + (patch.isEmpty ? 0 : 1)
        let entryId = (r.changes.last?.entry.id ?? 0) + 1
        let entry = EditHistoryEntry(id: entryId, revision: rev, author: author, kind: kind, label: String(label.prefix(200)), undoes: undoes,
                                     createdAt: Double(nowMs()))
        r.session.project = next
        r.session.revision = rev
        r.session.updatedBy = author
        r.session.updatedAt = Double(nowMs())
        r.changes.append(FakeEditChange(entry: entry, patch: patch, inverse: inverse))
        if let u = undoes, let i = r.changes.firstIndex(where: { $0.entry.id == u }) { r.changes[i].entry.undone = true }
        if r.changes.count > 500 { r.changes.removeFirst(r.changes.count - 500) }
        editSessions[id] = r
        if !patch.isEmpty { emitEdit(EditSessionEvent(sessionId: id, op: "patch", revision: rev, baseRevision: base, patch: patch, entry: entry)) }
        else { emitEdit(EditSessionEvent(sessionId: id, op: "log", entry: entry)) }
        return entry
    }

    private func staleError(_ id: String, _ base: Int) -> ApiError {
        ApiError("stale_revision", "The edit moved on (revision \(editSessions[id]?.session.revision ?? 0), you sent \(base)) · get it again and re-apply")
    }

    // MARK: MuseAPI

    public func openEditSession(_ req: EditSessionOpenRequest) throws -> EditSession {
        try editOwner()
        if req.fresh != true, req.takeId != EditV2.blankSourceId, let cur = editSessions.values.filter({ $0.session.takeId == req.takeId && $0.session.status == "open" })
            .max(by: { ($0.session.updatedAt ?? 0) < ($1.session.updatedAt ?? 0) }) {
            return view(cur)
        }
        let project: EditV2.Project
        if let p = req.project {
            // A blank project still being built may be empty (the server's validate draft mode).
        if !(p.isBlank && p.mainClips.isEmpty), let problem = EditV2.problem(p, paletteIds: Self.palettes(p)) { throw ApiError("bad_request", "project.\(problem.description)") }
            if p.sourceTakeId != req.takeId { throw ApiError("bad_request", "project.sourceTakeId: must be the session's take") }
            project = p
        } else if req.takeId == EditV2.blankSourceId {
            project = .blank()
        } else {
            guard let t = takes.first(where: { $0.id == req.takeId }) else { throw ApiError("not_found", "Take not found") }
            guard t.isVideo else { throw ApiError("bad_request", "takeId: must be a video take") }
            if let p2 = t.editsV2 { project = p2 } else {
                project = EditV2.withTakeLook(EditV2.fromV1(EditList(sourceTakeId: t.id, sourceDurationSec: t.durationSec ?? 8),
                                        EditV2.SourceFacts(width: t.width ?? 1080, height: t.height ?? 1920, fps: t.fps ?? 30, hasAudio: true)), take: t)
            }
        }
        let now = Double(nowMs())
        let s = EditSession(id: "es_" + shortId(), takeId: req.takeId, baseVersionId: req.baseVersionId, revision: 0, project: try JSONPatch.encode(project),
                            status: "open", updatedBy: Self.author(req.device), updatedAt: now)
        editSessions[s.id] = FakeEditSessionRecord(session: s)
        return view(editSessions[s.id]!)
    }

    public func editSession(id: String) throws -> EditSession { view(try record(id)) }

    public func pushEditPatch(sessionId id: String, _ req: EditPatchRequest) throws -> EditChangeResult {
        let r = try record(id)
        guard req.baseRevision == r.session.revision else { throw staleError(id, req.baseRevision) }
        let next: JSONValue
        do { next = try JSONPatch.apply(r.session.project, req.patch) } catch { throw ApiError("bad_request", "patch: \(error)") }
        _ = try checked(next, takeId: r.session.takeId)
        let entry = commit(id, next: next, author: Self.author(req.device), kind: "edit", label: req.label.isEmpty ? "Edit" : req.label)
        return EditChangeResult(revision: editSessions[id]!.session.revision, entry: entry)
    }

    public func undoEditChange(sessionId id: String, entryId: Int, device: String) throws -> EditChangeResult {
        try undo(id, entryId: entryId, author: Self.author(device))
    }

    private func undo(_ id: String, entryId: Int, author: String) throws -> EditChangeResult {
        let r = try record(id)
        guard let c = r.changes.first(where: { $0.entry.id == entryId }) else { throw ApiError("not_found", "Change not found") }
        if c.entry.undone { throw ApiError("already_undone", "That change was already undone") }
        if c.inverse.isEmpty { throw ApiError("bad_request", "That entry changed nothing") }
        let next: JSONValue
        do {
            next = try JSONPatch.apply(r.session.project, c.inverse)
            _ = try checked(next, takeId: r.session.takeId)
        } catch {
            throw ApiError("cannot_undo", "Later changes touch the same parts · undo those first")
        }
        let entry = commit(id, next: next, author: author, kind: "undo", label: "Undo: \(c.entry.label)", undoes: c.entry.id)
        return EditChangeResult(revision: editSessions[id]!.session.revision, entry: entry)
    }

    public func announceEditPresence(sessionId id: String, _ p: EditPresence) throws {
        _ = try record(id)
        editSessions[id]?.presence[p.device] = p
    }

    public func leaveEditSession(sessionId id: String, device: String) throws {
        _ = try record(id)
        editSessions[id]?.presence[device] = nil
    }

    public func uploadEditFrame(png: Data) throws -> String {
        let id = "up_" + shortId()
        let dir = storeDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("muse-fake-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("frame_\(id).png")
        try png.write(to: f)
        editUploads[id] = .image(f)
        return id
    }

    public func answerEditFrame(sessionId id: String, requestId: String, uploadId: String) throws {
        _ = try record(id)
        guard case .image? = editUploads[uploadId] else { throw ApiError("bad_request", "uploadId: an image upload of the studio") }
        editSessions[id]?.frameAnswers[requestId] = uploadId
    }

    public func answerEditAppRequest(sessionId id: String, requestId: String, _ answer: EditAppRequestAnswer) throws {
        let r = try record(id)
        guard var req = r.session.requests.first(where: { $0.id == requestId }) else { throw ApiError("not_found", "Request not found") }
        req.status = answer.status == "failed" ? "failed" : "done"
        req.versionId = answer.versionId
        req.error = answer.error
        editSessions[id]?.requestAnswers[requestId] = answer
        if let i = editSessions[id]?.session.requests.firstIndex(where: { $0.id == requestId }) { editSessions[id]?.session.requests[i] = req }
        emitEdit(EditSessionEvent(sessionId: id, op: "app_request", request: req))
    }

    public func answerEditPending(sessionId id: String, pendingId: String, approve: Bool) throws -> EditPending {
        let r = try record(id)
        guard let i = r.session.pending.firstIndex(where: { $0.id == pendingId }), r.session.pending[i].isWaiting else {
            throw ApiError("not_found", "Waiting request not found")
        }
        var p = r.session.pending[i]
        p.status = approve ? "running" : "declined"
        if approve { p.jobId = "ej_" + shortId() }
        editSessions[id]?.session.pending[i] = p
        emitEdit(EditSessionEvent(sessionId: id, op: "pending", pending: p))
        return p
    }

    public func closeEditSession(id: String) throws {
        _ = try record(id)
        editSessions[id]?.session.status = "closed"
        emitEdit(EditSessionEvent(sessionId: id, op: "closed"))
    }

    /// Continue a draft: open sessions, the last worked on (changed or left) first, without history.
    public func recentEditSessions(limit: Int) throws -> [EditSession] {
        try editOwner()
        // Like the server: when the person last worked on it (the view), else its last change.
        func touched(_ s: EditSession) -> Double { s.view?.at.flatMap { $0 > 0 ? $0 : nil } ?? (s.updatedAt ?? 0) }
        return editSessions.values.map(\.session).filter { $0.status == "open" }.sorted { touched($0) > touched($1) }
            .prefix(max(1, min(50, limit))).map { s in
                var v = view(editSessions[s.id]!, history: false)
                v.lastTouchedAt = touched(s)
                return v
            }
    }

    /// Where the editor was left (the server's clamps; `at` stamped here).
    public func saveEditSessionView(sessionId id: String, _ v: EditSessionView) throws {
        _ = try record(id)
        var v = v
        v.playhead = v.playhead.map { min(24 * 3600, max(0, $0)) }
        v.zoom = v.zoom.map { min(2000, max(1, $0)) }
        // Strictly later than the last change, so "left last" beats "changed last" even within one millisecond.
        v.at = max(Double(nowMs()), (editSessions[id]?.session.updatedAt ?? 0) + 1)
        editSessions[id]?.session.view = v
    }

    // MARK: Claude's side (tests and demos)

    /// The stored session (revision, project, history, the app's answers).
    public func fakeEditRecord(_ id: String) -> FakeEditSessionRecord? { editSessions[id] }

    /// Claude changes the edit (a JSON Patch, as one undoable change by "claude").
    @discardableResult
    public func fakeClaudePatch(sessionId id: String, _ patch: [EditPatchOp], label: String) throws -> EditHistoryEntry? {
        let r = try record(id)
        let next = try JSONPatch.apply(r.session.project, patch)
        _ = try checked(next, takeId: r.session.takeId)
        return commit(id, next: next, author: "claude", kind: "edit", label: label)
    }

    /// Claude undoes a change.
    public func fakeClaudeUndo(sessionId id: String, entryId: Int) throws -> EditChangeResult { try undo(id, entryId: entryId, author: "claude") }

    /// Claude asks for a paid helper; it waits for the owner's answer in the app.
    @discardableResult
    public func fakeClaudePending(sessionId id: String, kind: String, label: String, estimateUsd: Double) throws -> EditPending {
        _ = try record(id)
        let p = EditPending(id: "pa_" + shortId(), kind: kind, label: label, estimateUsd: estimateUsd, createdAt: Double(nowMs()))
        editSessions[id]?.session.pending.append(p)
        emitEdit(EditSessionEvent(sessionId: id, op: "pending", pending: p))
        commit(id, next: editSessions[id]!.session.project, author: "claude", kind: "tool",
               label: "Asked the owner: \(label) (about $\(String(format: "%.2f", estimateUsd)))")
        return p
    }

    /// Claude asks the online app (the Mac first) for the exact frame at `t`. Nil when no app can render.
    public func fakeFrameRequest(sessionId id: String, t: Double, width: Int = 540) throws -> String? {
        let r = try record(id)
        guard let app = Self.renderer(r) else { return nil }
        let rid = "fr_" + shortId()
        emitEdit(EditSessionEvent(sessionId: id, op: "frame_request", revision: r.session.revision, requestId: rid, t: t, width: width, device: app.device))
        return rid
    }

    /// Claude asks the online app to save a version or export. Nil when no app is online.
    public func fakeAppRequest(sessionId id: String, kind: String, name: String? = nil, preset: [String: JSONValue]? = nil) throws -> EditAppRequest? {
        let r = try record(id)
        guard let app = Self.renderer(r) else { return nil }
        // The owner's disclosure switches are not Claude's.
        let clean = preset?.filter { $0.key != "aiLabel" && $0.key != "c2pa" }
        let req = EditAppRequest(id: "ar_" + shortId(), kind: kind, name: name, preset: clean, device: app.device, at: Double(nowMs()))
        editSessions[id]?.session.requests.append(req)
        emitEdit(EditSessionEvent(sessionId: id, op: "app_request", request: req))
        return req
    }

    /// The app Claude's frames and save/export go to: the Mac first.
    static func renderer(_ r: FakeEditSessionRecord) -> EditPresence? {
        r.presence.values.filter(\.canRender).sorted { ($0.platform == "mac" ? 0 : 1, $0.device) < ($1.platform == "mac" ? 0 : 1, $1.device) }.first
    }
}
