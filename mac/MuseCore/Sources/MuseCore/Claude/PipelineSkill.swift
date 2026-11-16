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

/// The calls Settings uses. The server's client (HTTPClaudeAPI) and the demo one (FakeClaudeAPI, review screenshots) both have them.
public protocol PipelineSkillAPI: Sendable {
    func pipelineSkill() async throws -> PipelineSkillState
    func pipelineVersions() async throws -> [PipelineVersion]
    func pipelineDiff(_ version: Int) async throws -> PipelineDiff
    func pipelineRollback(to version: Int) async throws -> PipelineRollback
    func pipelineUndo() async throws -> PipelineRollback
    func pipelineDecide(_ id: String, approve: Bool) async throws -> PipelineProposal
    /// GET /v1/pipeline-skill/skill-files: the skill as Claude Code skill files (SKILL.md + reference/<page>.md).
    func pipelineSkillFiles() async throws -> PipelineSkillFiles
}

public struct PipelineSkillFile: Codable, Hashable, Sendable {
    public var path: String
    public var text: String
    public init(path: String, text: String) { self.path = path; self.text = text }
}
public struct PipelineSkillFiles: Codable, Hashable, Sendable {
    public var version: Int
    public var files: [PipelineSkillFile]
    public init(version: Int, files: [PipelineSkillFile]) { self.version = version; self.files = files }
}

/// Writes the skill into a Claude Code working folder as a project skill, so Claude Code's own skill loading finds it:
/// `<cwd>/.claude/skills/muse-edit-pipeline/SKILL.md` and `reference/<page>.md`. Only MUSE's own folders (~/MUSE/Claude/<thread>),
/// never ~/.claude. The folder is replaced each time (a retired page goes away); any other path from the server is skipped.
public enum PipelineSkillFolder {
    public static let name = "muse-edit-pipeline"

    /// SKILL.md or reference/<lower-case-dashes>.md, nothing else (no "..", no absolute paths).
    public static func safe(_ path: String) -> Bool {
        if path == "SKILL.md" { return true }
        guard path.hasPrefix("reference/"), path.hasSuffix(".md") else { return false }
        let slug = path.dropFirst("reference/".count).dropLast(3)
        return !slug.isEmpty && slug.count <= 48 && slug.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }

    /// Returns the skill folder it wrote.
    @discardableResult
    public static func write(_ skill: PipelineSkillFiles, into cwd: URL) throws -> URL {
        let fm = FileManager.default
        let folder = cwd.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let files = skill.files.filter { safe($0.path) }
        guard files.contains(where: { $0.path == "SKILL.md" }) else { return folder }
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder.appendingPathComponent("reference", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for f in files { try Data(f.text.utf8).write(to: folder.appendingPathComponent(f.path), options: .atomic) }
        return folder
    }
}

extension HTTPClaudeAPI: PipelineSkillAPI {
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
    /// GET /v1/pipeline-skill/skill-files
    public func pipelineSkillFiles() async throws -> PipelineSkillFiles { try await call("GET", "v1/pipeline-skill/skill-files") }
    public func pipelineDecide(_ id: String, approve: Bool) async throws -> PipelineProposal {
        try await call("POST", "v1/pipeline-skill/pending/\(try ClaudeIds.check(id))/\(approve ? "approve" : "decline")", NoBody())
    }
}

// MARK: Demo (review mode): a skill at version 3 with one small change in the changelog and one big change waiting.

final class FakePipelineSkill: @unchecked Sendable {
    static let shared = FakePipelineSkill()
    private let lock = NSLock()
    private struct Snap { var core: [String]; var pages: [PipelinePage]; var style: [PipelineStyleEntry] }
    private var history: [(PipelineVersion, Snap)] = []
    private var pending: [PipelineProposal] = []

    private init() {
        let rules = ["Never time from the picture. A shot starts on a hit. [proven]", "One stage per note: count the notes before choosing panels. [proven]",
                     "Before building an effect to hide a weak cut, ask whether the shot should be there at all. [trial]"]
        let pages = [PipelinePage(name: "cutouts", title: "Cut-outs", status: "proven", score: 4, repeatable: nil, uses: 4),
                     PipelinePage(name: "hits", title: "Hits: flash, negative, colour split, punch-in", status: "trial", score: 1, repeatable: nil, uses: 1)]
        let style = [PipelineStyleEntry(id: "hs_1", text: "These edits are cut like comics: panels opening over running video.", times: 1)]
        let v1 = Snap(core: rules, pages: pages, style: style)
        var v2 = v1; v2.style.append(PipelineStyleEntry(id: "hs_2", text: "Avoid: “too fast” (the intro cuts)", times: 1))
        var v3 = v2; v3.pages.append(PipelinePage(name: "whip-pan", title: "Whip pan between moving shots", status: "trial", score: 1, repeatable: nil, uses: 1))
        let t = Date().timeIntervalSince1970 * 1000
        history = [
            (PipelineVersion(version: 1, changelog: [PipelineChangelogLine(what: "Version 1 from the Icon edit", why: "first use", editId: nil, kind: "seed")], by: "seed", createdAt: t - 86_400_000 * 2), v1),
            (PipelineVersion(version: 2, changelog: [PipelineChangelogLine(what: "House style: “Avoid: “too fast” (the intro cuts)”", why: "owner reaction", editId: "es_demo1", kind: "small")], by: "claude", createdAt: t - 86_400_000), v2),
            (PipelineVersion(version: 3, changelog: [PipelineChangelogLine(what: "New trial technique “Whip pan between moving shots” (whip-pan)", why: "worked in this edit", editId: "es_demo2", kind: "small")], by: "claude", createdAt: t - 3_600_000), v3),
        ]
        pending = [PipelineProposal(id: "pp_demo1", op: "core_remove", why: "the owner cut that shot instead of hiding it twice", reason: "changes a core rule", editId: "es_demo2",
                                    status: "pending", target: "core", before: rules[2], after: "", version: nil)]
    }
    private func locked<T>(_ f: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try f() }
    private func add(_ snap: Snap, _ line: PipelineChangelogLine, by: String) -> Int {
        let v = (history.last?.0.version ?? 0) + 1
        history.append((PipelineVersion(version: v, changelog: [line], by: by, createdAt: Date().timeIntervalSince1970 * 1000), snap))
        return v
    }
    func state() -> PipelineSkillState {
        locked {
            let (v, s) = history.last!
            return PipelineSkillState(version: v.version, coreChars: 4497 - (3 - s.core.count) * 90, coreBudget: 6000, pages: s.pages, houseStyle: s.style,
                                      pending: pending, templateHints: [])
        }
    }
    func versions() -> [PipelineVersion] { locked { Array(history.map(\.0).reversed()) } }
    func diff(_ version: Int) throws -> PipelineDiff {
        try locked {
            guard let i = history.firstIndex(where: { $0.0.version == version }) else { throw ApiError("not_found", "Skill version not found") }
            let b = history[i].1, a: Snap? = i > 0 ? history[i - 1].1 : nil
            var out: [PipelineDiffChange] = []
            if a?.core != b.core { out.append(PipelineDiffChange(section: "core", name: "core", before: (a?.core ?? []).joined(separator: "\n"), after: b.core.joined(separator: "\n"))) }
            for p in b.pages where !(a?.pages.contains(p) ?? false) { out.append(PipelineDiffChange(section: "page", name: p.name, before: "", after: p.title)) }
            for e in b.style where !(a?.style.contains(e) ?? false) { out.append(PipelineDiffChange(section: "house style", name: e.id, before: "", after: e.text)) }
            return PipelineDiff(version: version, changes: out)
        }
    }
    func rollback(to version: Int) throws -> PipelineRollback {
        try locked {
            guard let target = history.first(where: { $0.0.version == version }) else { throw ApiError("not_found", "Skill version not found") }
            let v = add(target.1, PipelineChangelogLine(what: "Rolled back to version \(version)", why: "the owner rolled back", editId: nil, kind: "rollback"), by: "owner")
            return PipelineRollback(version: v, rolledBackTo: version)
        }
    }
    func undo() throws -> PipelineRollback {
        let cur = locked { history.last!.0.version }
        guard cur > 1 else { throw ApiError("bad_request", "Nothing to undo") }
        return try rollback(to: cur - 1)
    }
    func decide(_ id: String, approve: Bool) throws -> PipelineProposal {
        try locked {
            guard let i = pending.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "Proposal not found") }
            var p = pending.remove(at: i)
            p.status = approve ? "approved" : "declined"
            if approve {
                var s = history.last!.1
                s.core.removeAll { $0 == p.before }
                p.version = add(s, PipelineChangelogLine(what: "Core: removed “\(p.before)”", why: "\(p.why) (approved by the owner)", editId: p.editId, kind: "big"), by: "owner")
            }
            return p
        }
    }
}

extension FakeClaudeAPI: PipelineSkillAPI {
    public func pipelineSkill() async throws -> PipelineSkillState { FakePipelineSkill.shared.state() }
    public func pipelineVersions() async throws -> [PipelineVersion] { FakePipelineSkill.shared.versions() }
    public func pipelineDiff(_ version: Int) async throws -> PipelineDiff { try FakePipelineSkill.shared.diff(version) }
    public func pipelineRollback(to version: Int) async throws -> PipelineRollback { try FakePipelineSkill.shared.rollback(to: version) }
    public func pipelineUndo() async throws -> PipelineRollback { try FakePipelineSkill.shared.undo() }
    public func pipelineDecide(_ id: String, approve: Bool) async throws -> PipelineProposal { try FakePipelineSkill.shared.decide(id, approve: approve) }
    public func pipelineSkillFiles() async throws -> PipelineSkillFiles {
        let s = FakePipelineSkill.shared.state()
        let index = s.pages.map { "- [\($0.title)](reference/\($0.name).md) (\($0.status))" }.joined(separator: "\n")
        return PipelineSkillFiles(version: s.version, files: [PipelineSkillFile(path: "SKILL.md", text: "---\nname: muse-edit-pipeline\ndescription: MUSE's edit pipeline (demo).\n---\n\n# MUSE Edit Pipeline (demo)\n\n\(index)\n")]
            + s.pages.map { PipelineSkillFile(path: "reference/\($0.name).md", text: "# \($0.title)\n") })
    }
}
