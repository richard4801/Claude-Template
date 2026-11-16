import Foundation

// The Edit pipeline skill (server: editor/pipelineSkill.ts): the versioned how-to Claude reads at the start of an edit and
// improves after it. Settings → Claude shows its version and changelog, rolls it back, and answers the big changes that
// wait for the owner. Owner only.

public struct PipelineChangelogLine: Codable, Hashable, Sendable {
    public var what: String
    public var why: String
    public var editId: String?
    /// small | big | owner | rollback | seed
    public var kind: String
}

public struct PipelineVersion: Codable, Hashable, Sendable, Identifiable {
    public var version: Int
    public var changelog: [PipelineChangelogLine]
    public var by: String
    public var createdAt: Double
    public var id: Int { version }
}

public struct PipelinePage: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var title: String
    /// trial | proven | retired
    public var status: String
    public var score: Int
    public var repeatable: Bool?
    public var uses: Int?
    public var id: String { name }
}

public struct PipelineStyleEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var times: Int?
}

/// A big change waiting for the owner (Approve / Decline), with what it changes before → after.
public struct PipelineProposal: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var op: String
    public var why: String
    public var reason: String
    public var editId: String?
    public var status: String
    public var target: String?
    public var before: String
    public var after: String
    public var version: Int?
}

public struct PipelineHint: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var title: String
    public var id: String { name }
}

public struct PipelineSkillState: Codable, Hashable, Sendable {
    public var version: Int
    public var coreChars: Int
    public var coreBudget: Int
    public var pages: [PipelinePage]
    public var houseStyle: [PipelineStyleEntry]
    public var pending: [PipelineProposal]
    public var templateHints: [PipelineHint]
}

public struct PipelineDiffChange: Codable, Hashable, Sendable {
    /// core | page | house style
    public var section: String
    public var name: String
    public var before: String
    public var after: String
}

public struct PipelineDiff: Codable, Hashable, Sendable {
    public var version: Int
    public var changes: [PipelineDiffChange]
}

public struct PipelineRollback: Codable, Hashable, Sendable {
    public var version: Int
    public var rolledBackTo: Int
}

extension HTTPClaudeAPI {
    private struct RollbackBody: Encodable { var version: Int }
    private struct NoBody: Encodable {}

    /// GET /v1/pipeline-skill
    public func pipelineSkill() async throws -> PipelineSkillState { try await call("GET", "v1/pipeline-skill") }
    /// GET /v1/pipeline-skill/versions (newest first)
    public func pipelineVersions() async throws -> [PipelineVersion] { try await call("GET", "v1/pipeline-skill/versions") }
    /// GET /v1/pipeline-skill/versions/:v/diff: what that version changed, before → after.
    public func pipelineDiff(_ version: Int) async throws -> PipelineDiff { try await call("GET", "v1/pipeline-skill/versions/\(version)/diff") }
    /// POST /v1/pipeline-skill/rollback: a new version with that version's content (nothing is lost).
    public func pipelineRollback(to version: Int) async throws -> PipelineRollback { try await call("POST", "v1/pipeline-skill/rollback", RollbackBody(version: version)) }
    /// POST /v1/pipeline-skill/undo: back to the version before the newest.
    public func pipelineUndo() async throws -> PipelineRollback { try await call("POST", "v1/pipeline-skill/undo", NoBody()) }
    /// POST /v1/pipeline-skill/pending/:id/approve | decline
    public func pipelineDecide(_ id: String, approve: Bool) async throws -> PipelineProposal {
        try await call("POST", "v1/pipeline-skill/pending/\(try ClaudeIds.check(id))/\(approve ? "approve" : "decline")", NoBody())
    }
}
