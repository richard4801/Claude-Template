import Foundation

// Claude in the AI Suite (workstream 2, phase B; contract from workstream 1, plans/api.md "Suite assist"): one draft shared by
// Claude and the composer. Claude edits it on the server with MCP tools (suite_options, suite_get_draft, suite_set_draft,
// suite_estimate, suite_request_shot, suite_feed); the app applies `assist.draft` from the `suiteAssist` live event or a GET, and
// sends the owner's own composer edits back with PATCH so Claude sees them. A paid step is a `Pending` the owner approves in
// the app: nothing renders without that yes.

/// A paid step Claude asked for (`suite_request_shot` with confirm). `status`: waiting | declined | done | failed.
/// `maxUsd` is the price the owner approves: the shot never runs above it (`409 price_changed`).
public struct SuitePending: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// "suite_request_shot".
    public var kind: String
    /// The server's button label ("Generate · 5 s · $0.40").
    public var label: String
    public var estimateUsd: Double
    /// The price being approved (older replies without it: the estimate).
    public var maxUsd: Double
    public var status: String
    /// Once it has run.
    public var jobId: String?
    /// Why it failed (status "failed"), in the server's words.
    public var error: String?
    public var createdAt: Int64

    public init(id: String, kind: String = "suite_request_shot", label: String, estimateUsd: Double, maxUsd: Double? = nil, status: String = "waiting",
                jobId: String? = nil, error: String? = nil, createdAt: Int64 = 0) {
        self.id = id
        self.kind = kind
        self.label = label
        self.estimateUsd = estimateUsd
        self.maxUsd = maxUsd ?? estimateUsd
        self.status = status
        self.jobId = jobId
        self.error = error
        self.createdAt = createdAt
    }

    public var isWaiting: Bool { status == "waiting" }
    public var isFailed: Bool { status == "failed" }

    enum CodingKeys: String, CodingKey { case id, kind, label, estimateUsd, maxUsd, status, jobId, error, createdAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.v(.kind, "suite_request_shot")
        label = c.v(.label, "")
        estimateUsd = c.v(.estimateUsd, 0.0)
        maxUsd = c.o(.maxUsd) ?? estimateUsd
        status = c.v(.status, "waiting")
        jobId = c.o(.jobId)
        error = c.o(.error)
        createdAt = SuiteTime.ms(c, .createdAt)
    }
}

/// `POST /v1/suite/assist`, `GET`/`PATCH /v1/suite/assist/{id}`: the shared draft, its revision, what Generate would send,
/// the rig check and Claude's paid asks.
public struct SuiteAssist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var draft: SuiteDraft?
    public var revision: Int
    /// What Generate would send for this draft.
    public var request: ShotRequest?
    public var warnings: [RigWarning]
    public var pending: [SuitePending]
    public var updatedAt: Int64

    public init(id: String, draft: SuiteDraft? = nil, revision: Int = 1, request: ShotRequest? = nil, warnings: [RigWarning] = [], pending: [SuitePending] = [],
                updatedAt: Int64 = 0) {
        self.id = id
        self.draft = draft
        self.revision = revision
        self.request = request
        self.warnings = warnings
        self.pending = pending
        self.updatedAt = updatedAt
    }

    /// The first ask still waiting for the owner.
    public var waiting: SuitePending? { pending.first(where: \.isWaiting) }
    /// The newest ask, when it failed (its reason is shown in plain words).
    public var failed: SuitePending? { pending.last.flatMap { $0.isFailed ? $0 : nil } }

    enum CodingKeys: String, CodingKey { case id, draft, revision, request, warnings, pending, updatedAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        draft = c.o(.draft)
        revision = c.v(.revision, 0)
        request = c.o(.request)
        warnings = c.v(.warnings, [])
        pending = c.v(.pending, [])
        updatedAt = SuiteTime.ms(c, .updatedAt)
    }
}

/// POST /v1/suite/assist
public struct SuiteAssistCreate: Codable, Hashable, Sendable {
    public var draft: SuiteDraft?
    public var fromJobId: String?
    public init(draft: SuiteDraft? = nil, fromJobId: String? = nil) {
        self.draft = draft
        self.fromJobId = fromJobId
    }
}

/// PATCH /v1/suite/assist/{id}: the owner's own edits. `409 stale` when `baseRevision` is behind: GET again and merge.
public struct SuiteAssistPatch: Codable, Hashable, Sendable {
    public var draft: SuiteDraft
    public var baseRevision: Int?
    public init(draft: SuiteDraft, baseRevision: Int? = nil) {
        self.draft = draft
        self.baseRevision = baseRevision
    }
}

/// POST /v1/suite/assist/{id}/pending/{pid}
public struct SuitePendingAnswer: Codable, Hashable, Sendable {
    public var approve: Bool
    public init(approve: Bool) { self.approve = approve }
}

/// The live event `{type: "suiteAssist", assist}`.
struct SuiteAssistEnvelope: Decodable {
    var assist: SuiteAssist?
}

/// The assist calls (owner only: `403 owner_only` for members). Separate from MuseAPI so older test doubles still build.
public protocol SuiteAssistAPI: Sendable {
    func createSuiteAssist(_ body: SuiteAssistCreate) async throws -> SuiteAssist
    func suiteAssist(id: String) async throws -> SuiteAssist
    /// `409 stale` when `baseRevision` is behind the server's.
    func patchSuiteAssist(id: String, _ body: SuiteAssistPatch) async throws -> SuiteAssist
    /// Approve runs the shot at the approved price (`409 price_changed` when it moved); decline tells Claude not now.
    func answerSuitePending(assistId: String, pendingId: String, approve: Bool) async throws -> SuitePending
    /// An image for a Claude message: the normal image upload (presign → PUT → confirm). → its upload id and address.
    func uploadClaudeImage(name: String, data: Data, mime: String) async throws -> ClaudeAttachment
}

extension HTTPMuseAPI: SuiteAssistAPI {
    private func assistBody<B: Encodable>(_ b: B) throws -> Data { try JSONEncoder().encode(b) }

    public func createSuiteAssist(_ body: SuiteAssistCreate) async throws -> SuiteAssist {
        try await suiteCall("POST", "v1/suite/assist", body: assistBody(body))
    }
    public func suiteAssist(id: String) async throws -> SuiteAssist {
        try await suiteCall("GET", "v1/suite/assist/\(Self.pathKey(id))")
    }
    public func patchSuiteAssist(id: String, _ body: SuiteAssistPatch) async throws -> SuiteAssist {
        try await suiteCall("PATCH", "v1/suite/assist/\(Self.pathKey(id))", body: assistBody(body))
    }
    public func answerSuitePending(assistId: String, pendingId: String, approve: Bool) async throws -> SuitePending {
        try await suiteCall("POST", "v1/suite/assist/\(Self.pathKey(assistId))/pending/\(Self.pathKey(pendingId))", body: assistBody(SuitePendingAnswer(approve: approve)))
    }
    public func uploadClaudeImage(name: String, data: Data, mime: String) async throws -> ClaudeAttachment {
        guard let id = try await presignAndPut(kind: "image", contentType: mime, body: .data(data), progress: nil) else {
            throw ApiError("upload_failed", "This server can't take images for Claude yet")
        }
        let ref: ImageRef = try await suiteCall("POST", "v1/uploads/\(Self.pathKey(id))/confirm", body: assistBody(ConfirmBody(meta: nil)))
        return ClaudeAttachment(uploadId: id, mimeType: mime, bytes: data.count, url: absolutize(ref).url)
    }
}
