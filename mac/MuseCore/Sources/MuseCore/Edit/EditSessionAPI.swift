import Foundation

// Edit sessions (workstream 3, plans/api.md "Edit sessions", plans/claude-editing.md A): the live, revisioned copy of a take's
// EditProject v2 that the owner's apps and Claude share. Owner only. Every change is a JSON Patch (JSONPatch.swift) with its
// inverse on the server, so every change, Claude's too, is undoable. Decoding is lenient: a field the server adds later never
// breaks the session.

/// One change in the session's history (newest first). `id` is the server's change number (undo takes it).
public struct EditHistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var revision: Int
    /// "app:<device>" or "claude".
    public var author: String
    public var byClaude: Bool
    /// edit | undo | tool | reset
    public var kind: String
    public var label: String
    public var undoes: Int?
    public var undone: Bool
    public var createdAt: Double
    /// Claude added, changed or removed a mask, Invert, green-screen key or cut-out: one plain line ("Added an inverted
    /// oval mask to clip 2"), shown in the chat with Undo (server editor/maskNotice.ts).
    public var notice: String?

    public init(id: Int, revision: Int, author: String, byClaude: Bool? = nil, kind: String = "edit", label: String, undoes: Int? = nil,
                undone: Bool = false, createdAt: Double = 0, notice: String? = nil) {
        self.id = id; self.revision = revision; self.author = author; self.byClaude = byClaude ?? (author == "claude"); self.kind = kind
        self.label = label; self.undoes = undoes; self.undone = undone; self.createdAt = createdAt; self.notice = notice
    }

    enum CodingKeys: String, CodingKey { case id, revision, author, byClaude, kind, label, undoes, undone, createdAt, notice }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let n = try? c.decode(Int.self, forKey: .id) { id = n } else { id = Int(try c.decode(String.self, forKey: .id)) ?? 0 }
        revision = (try? c.decode(Int.self, forKey: .revision)) ?? 0
        author = (try? c.decode(String.self, forKey: .author)) ?? "app"
        byClaude = (try? c.decode(Bool.self, forKey: .byClaude)) ?? (author == "claude")
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "edit"
        label = (try? c.decode(String.self, forKey: .label)) ?? "Edit"
        undoes = try? c.decodeIfPresent(Int.self, forKey: .undoes)
        undone = (try? c.decode(Bool.self, forKey: .undone)) ?? false
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        notice = try? c.decodeIfPresent(String.self, forKey: .notice)
    }

    /// A change that can still be undone (not a note, not undone yet).
    public var canUndo: Bool { !undone && kind != "tool" }
}

/// A paid helper Claude asked for, waiting for the owner's yes.
public struct EditPending: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// captions | cuts | matte | denoise | beats
    public var kind: String
    public var label: String
    public var estimateUsd: Double
    /// waiting | approved | declined | running | done | failed
    public var status: String
    public var jobId: String?
    public var createdAt: Double

    public init(id: String, kind: String, label: String, estimateUsd: Double, status: String = "waiting", jobId: String? = nil, createdAt: Double = 0) {
        self.id = id; self.kind = kind; self.label = label; self.estimateUsd = estimateUsd; self.status = status; self.jobId = jobId; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, kind, label, estimateUsd, status, jobId, createdAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        label = (try? c.decode(String.self, forKey: .label)) ?? "AI helper"
        estimateUsd = (try? c.decode(Double.self, forKey: .estimateUsd)) ?? 0
        status = (try? c.decode(String.self, forKey: .status)) ?? "waiting"
        jobId = try? c.decodeIfPresent(String.self, forKey: .jobId)
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
    }

    public var isWaiting: Bool { status == "waiting" }
    /// "Claude wants to run Remove background · about $0.40"
    public var prompt: String { "Claude wants to run \(label) · about $" + String(format: "%.2f", estimateUsd) }
}

/// A save or export Claude asked an online app for.
public struct EditAppRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// save | export
    public var kind: String
    public var name: String?
    /// Export settings Claude chose (`resolution`, `fps`, `ratio`, `codec`, `captions`). Never the disclosure switches.
    public var preset: [String: JSONValue]?
    public var device: String
    /// sent | done | failed
    public var status: String
    public var versionId: String?
    public var error: String?
    public var at: Double

    public init(id: String, kind: String, name: String? = nil, preset: [String: JSONValue]? = nil, device: String, status: String = "sent",
                versionId: String? = nil, error: String? = nil, at: Double = 0) {
        self.id = id; self.kind = kind; self.name = name; self.preset = preset; self.device = device; self.status = status
        self.versionId = versionId; self.error = error; self.at = at
    }

    enum CodingKeys: String, CodingKey { case id, kind, name, preset, device, status, versionId, error, at }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "save"
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        preset = try? c.decodeIfPresent([String: JSONValue].self, forKey: .preset)
        device = (try? c.decode(String.self, forKey: .device)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "sent"
        versionId = try? c.decodeIfPresent(String.self, forKey: .versionId)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        at = (try? c.decode(Double.self, forKey: .at)) ?? 0
    }
}

/// An app with the edit open (POST …/presence every 30 s).
public struct EditPresence: Codable, Hashable, Sendable {
    public var device: String
    public var label: String
    /// android | mac | other
    public var platform: String
    public var canRender: Bool
    /// Edit's preview on this app (the view and the red safe-area box), so Claude knows what the person sees.
    public var preview: EditPreview?
    public init(device: String, label: String, platform: String = "mac", canRender: Bool = true, preview: EditPreview? = nil) {
        self.device = device; self.label = label; self.platform = platform; self.canRender = canRender; self.preview = preview
    }
}

/// GET/POST /v1/edit-sessions → the session. `project` is the server's JSON as-is (patches apply to it).
public struct EditSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var takeId: String
    public var baseVersionId: String?
    public var revision: Int
    public var project: JSONValue
    public var durationSec: Double?
    /// open | closed
    public var status: String
    public var updatedBy: String?
    public var updatedAt: Double?
    public var pending: [EditPending]
    public var online: [EditPresence]
    public var requests: [EditAppRequest]
    public var history: [EditHistoryEntry]?
    /// Where an editor was last left on this session (continue a draft; EditRecent.swift).
    public var view: EditSessionView?
    /// The later of the last change and `view.at` (ms), from GET /v1/edit-sessions?recent=1.
    public var lastTouchedAt: Double?

    public init(id: String, takeId: String, baseVersionId: String? = nil, revision: Int, project: JSONValue, durationSec: Double? = nil, status: String = "open",
                updatedBy: String? = nil, updatedAt: Double? = nil, pending: [EditPending] = [], online: [EditPresence] = [], requests: [EditAppRequest] = [],
                history: [EditHistoryEntry]? = nil, view: EditSessionView? = nil, lastTouchedAt: Double? = nil) {
        self.id = id; self.takeId = takeId; self.baseVersionId = baseVersionId; self.revision = revision; self.project = project
        self.durationSec = durationSec; self.status = status; self.updatedBy = updatedBy; self.updatedAt = updatedAt; self.pending = pending
        self.online = online; self.requests = requests; self.history = history; self.view = view; self.lastTouchedAt = lastTouchedAt
    }

    enum CodingKeys: String, CodingKey { case id, takeId, baseVersionId, revision, project, durationSec, status, updatedBy, updatedAt, pending, online, requests, history, view, lastTouchedAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        takeId = (try? c.decode(String.self, forKey: .takeId)) ?? ""
        baseVersionId = try? c.decodeIfPresent(String.self, forKey: .baseVersionId)
        revision = try c.decode(Int.self, forKey: .revision)
        project = try c.decode(JSONValue.self, forKey: .project)
        durationSec = try? c.decodeIfPresent(Double.self, forKey: .durationSec)
        status = (try? c.decode(String.self, forKey: .status)) ?? "open"
        updatedBy = try? c.decodeIfPresent(String.self, forKey: .updatedBy)
        updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
        pending = (try? c.decode([EditPending].self, forKey: .pending)) ?? []
        online = (try? c.decode([EditPresence].self, forKey: .online)) ?? []
        requests = (try? c.decode([EditAppRequest].self, forKey: .requests)) ?? []
        history = try? c.decodeIfPresent([EditHistoryEntry].self, forKey: .history)
        view = try? c.decodeIfPresent(EditSessionView.self, forKey: .view)
        lastTouchedAt = try? c.decodeIfPresent(Double.self, forKey: .lastTouchedAt)
    }
}

/// POST /v1/edit-sessions
public struct EditSessionOpenRequest: Codable, Hashable, Sendable {
    public var takeId: String
    public var project: EditV2.Project?
    public var baseVersionId: String?
    public var device: String?
    public var fresh: Bool?
    public init(takeId: String, project: EditV2.Project? = nil, baseVersionId: String? = nil, device: String? = nil, fresh: Bool? = nil) {
        self.takeId = takeId; self.project = project; self.baseVersionId = baseVersionId; self.device = device; self.fresh = fresh
    }
}

/// POST …/{id}/patch
public struct EditPatchRequest: Codable, Hashable, Sendable {
    public var baseRevision: Int
    public var patch: [EditPatchOp]
    public var label: String
    public var device: String
    public init(baseRevision: Int, patch: [EditPatchOp], label: String, device: String) {
        self.baseRevision = baseRevision; self.patch = patch; self.label = label; self.device = device
    }
}

/// → `{revision, entry}` from patch / reset / undo.
public struct EditChangeResult: Codable, Hashable, Sendable {
    public var revision: Int
    public var entry: EditHistoryEntry?
    public init(revision: Int, entry: EditHistoryEntry?) { self.revision = revision; self.entry = entry }
}

/// POST …/{id}/requests/{requestId}
public struct EditAppRequestAnswer: Codable, Hashable, Sendable {
    /// done | failed
    public var status: String
    public var versionId: String?
    public var error: String?
    public init(status: String, versionId: String? = nil, error: String? = nil) { self.status = status; self.versionId = versionId; self.error = error }
    public static func done(versionId: String?) -> EditAppRequestAnswer { EditAppRequestAnswer(status: "done", versionId: versionId) }
    public static func failed(_ error: String) -> EditAppRequestAnswer { EditAppRequestAnswer(status: "failed", error: error) }
}

/// An `edit` event (`ApiEvent.edit`): `{type: "edit", sessionId, op, …}`. Owners only.
public struct EditSessionEvent: Codable, Hashable, Sendable {
    public var sessionId: String
    /// patch | log | pending | frame_request | app_request | closed
    public var op: String
    public var revision: Int?
    public var baseRevision: Int?
    public var patch: [EditPatchOp]?
    public var entry: EditHistoryEntry?
    public var pending: EditPending?
    public var request: EditAppRequest?
    /// frame_request: the request, the time (timeline seconds), the width wanted and the device asked.
    public var requestId: String?
    public var t: Double?
    public var width: Int?
    public var device: String?

    public init(sessionId: String, op: String, revision: Int? = nil, baseRevision: Int? = nil, patch: [EditPatchOp]? = nil, entry: EditHistoryEntry? = nil,
                pending: EditPending? = nil, request: EditAppRequest? = nil, requestId: String? = nil, t: Double? = nil, width: Int? = nil, device: String? = nil) {
        self.sessionId = sessionId; self.op = op; self.revision = revision; self.baseRevision = baseRevision; self.patch = patch; self.entry = entry
        self.pending = pending; self.request = request; self.requestId = requestId; self.t = t; self.width = width; self.device = device
    }

    enum CodingKeys: String, CodingKey { case sessionId, op, revision, baseRevision, patch, entry, pending, request, requestId, t, width, device }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sessionId = (try? c.decode(String.self, forKey: .sessionId)) ?? ""
        op = (try? c.decode(String.self, forKey: .op)) ?? ""
        revision = try? c.decodeIfPresent(Int.self, forKey: .revision)
        baseRevision = try? c.decodeIfPresent(Int.self, forKey: .baseRevision)
        patch = try? c.decodeIfPresent([EditPatchOp].self, forKey: .patch)
        entry = try? c.decodeIfPresent(EditHistoryEntry.self, forKey: .entry)
        pending = try? c.decodeIfPresent(EditPending.self, forKey: .pending)
        request = try? c.decodeIfPresent(EditAppRequest.self, forKey: .request)
        requestId = try? c.decodeIfPresent(String.self, forKey: .requestId)
        t = try? c.decodeIfPresent(Double.self, forKey: .t)
        let w: Double? = try? c.decodeIfPresent(Double.self, forKey: .width)
        width = w.map { Int($0.rounded()) }
        device = try? c.decodeIfPresent(String.self, forKey: .device)
    }

    /// The event inside an `edit` ApiEvent, read from the same JSON object.
    static func fromApiEvent(_ d: Decoder) -> EditSessionEvent? {
        guard let e = try? EditSessionEvent(from: d), !e.sessionId.isEmpty, !e.op.isEmpty else { return nil }
        return e
    }
}
