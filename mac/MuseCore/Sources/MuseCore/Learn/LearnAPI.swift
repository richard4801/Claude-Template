import Foundation

/// The learning editor's endpoints (plans/api.md "Learning editor", workstream 3's server). Owner only: members get 403.
public protocol LearnAPI: Sendable {
    func playbook() async throws -> [LearnRule]
    func addRule(_ req: LearnRuleRequest) async throws -> LearnRule
    func patchRule(_ id: String, _ req: LearnRuleRequest) async throws -> LearnRule
    func deleteRule(_ id: String) async throws
    func lessons() async throws -> [LearnLesson]
    func corrections(limit: Int) async throws -> [LearnCorrection]
    /// The whole library, newest first (the screen searches and filters it the way the server does).
    func recipes(limit: Int) async throws -> [LearnRecipe]
    /// One recipe with its `muse.recipe/1` body.
    func recipe(_ id: String) async throws -> LearnRecipe
    func patchRecipe(_ id: String, _ patch: LearnRecipePatch) async throws -> LearnRecipe
    /// Removes it from the library only: the reference and the take stay.
    func deleteRecipe(_ id: String) async throws
    func nearest(recipeId: String, k: Int) async throws -> LearnNearest
    func gaps(limit: Int) async throws -> [LearnGap]
}

public enum LearnIds {
    /// Rule ids are `rule_…`; anything else is refused before it reaches a URL.
    public static func rule(_ id: String) throws -> String {
        guard id.range(of: #"^rule_[A-Za-z0-9_]{1,64}$"#, options: .regularExpression) != nil else { throw ApiError("bad_id", "That isn't a rule") }
        return id
    }

    /// Recipe ids are `rcp_…`; anything else is refused before it reaches a URL.
    public static func recipe(_ id: String) throws -> String {
        guard id.range(of: #"^rcp_[A-Za-z0-9_]{1,64}$"#, options: .regularExpression) != nil else { throw ApiError("bad_id", "That isn't a recipe") }
        return id
    }

    /// A reference's poster (authenticated; load with the session token). The reference's own id is checked first.
    public static func posterPath(referenceId: String) -> String? {
        guard let id = try? RecreateIds.check(referenceId) else { return nil }
        return "/v1/recreate/references/\(id)/poster"
    }
}

// MARK: HTTP

extension HTTPMuseAPI: LearnAPI {
    private static func clamp(_ n: Int, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, n)) }

    public func playbook() async throws -> [LearnRule] { try await suiteCall("GET", "v1/learn/playbook") }
    public func addRule(_ req: LearnRuleRequest) async throws -> LearnRule {
        try await suiteCall("POST", "v1/learn/playbook", body: try JSONEncoder().encode(req))
    }
    public func patchRule(_ id: String, _ req: LearnRuleRequest) async throws -> LearnRule {
        try await suiteCall("PATCH", "v1/learn/playbook/\(try LearnIds.rule(id))", body: try JSONEncoder().encode(req))
    }
    public func deleteRule(_ id: String) async throws { try await suiteSend("DELETE", "v1/learn/playbook/\(try LearnIds.rule(id))") }
    public func lessons() async throws -> [LearnLesson] { try await suiteCall("GET", "v1/learn/lessons") }
    public func corrections(limit: Int) async throws -> [LearnCorrection] {
        try await suiteCall("GET", "v1/learn/corrections?limit=\(Self.clamp(limit, 1, 200))")
    }
    public func recipes(limit: Int) async throws -> [LearnRecipe] {
        try await suiteCall("GET", "v1/learn/recipes?limit=\(Self.clamp(limit, 1, 200))")
    }
    public func recipe(_ id: String) async throws -> LearnRecipe { try await suiteCall("GET", "v1/learn/recipes/\(try LearnIds.recipe(id))") }
    public func patchRecipe(_ id: String, _ patch: LearnRecipePatch) async throws -> LearnRecipe {
        try await suiteCall("PATCH", "v1/learn/recipes/\(try LearnIds.recipe(id))", body: try JSONEncoder().encode(patch))
    }
    public func deleteRecipe(_ id: String) async throws { try await suiteSend("DELETE", "v1/learn/recipes/\(try LearnIds.recipe(id))") }
    public func nearest(recipeId: String, k: Int) async throws -> LearnNearest {
        try await suiteCall("GET", "v1/learn/recipes/nearest?recipeId=\(try LearnIds.recipe(recipeId))&k=\(Self.clamp(k, 1, 10))")
    }
    public func gaps(limit: Int) async throws -> [LearnGap] { try await suiteCall("GET", "v1/learn/gaps?limit=\(Self.clamp(limit, 1, 200))") }
}

// MARK: Demo

/// Demo mode's learning editor: a playbook with rules in several areas (pinned, from Claude, learned), lessons,
/// corrections, a library of references and edits (Recreate's "Summer cut" among them) and two gaps. Changes stay in
/// memory; nothing reaches a server. `failNext` and `empty` drive the error and empty states in tests.
public final class FakeLearnAPI: LearnAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [LearnRule]
    private var lessonList: [LearnLesson]
    private var correctionList: [LearnCorrection]
    private var library: [LearnRecipe]
    private var gapList: [LearnGap]
    private var next = 100
    /// The next call throws (a dropped connection), once.
    public var failNext = false

    public init(empty: Bool = false, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        if empty {
            rules = []; lessonList = []; correctionList = []; library = []; gapList = []
        } else {
            let d = LearnDemo(now: now)
            rules = d.rules; lessonList = d.lessons; correctionList = d.corrections; library = d.recipes; gapList = d.gaps
        }
    }

    private func with<T>(_ f: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if failNext { failNext = false; throw ApiError("offline", "Couldn't reach MUSE") }
        return try f()
    }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Pinned first, then the best evidenced, then the newest (the server's order).
    private func sorted() -> [LearnRule] {
        rules.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.evidence.count != b.evidence.count { return a.evidence.count > b.evidence.count }
            return a.updatedAt > b.updatedAt
        }
    }

    private static func check(_ req: LearnRuleRequest, partial: Bool) throws {
        if let t = req.text ?? (partial ? nil : "") {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { throw ApiError("bad_request", "Say what Claude should do") }
            if s.count > Learn.maxRuleChars { throw ApiError("bad_request", "A rule is at most \(Learn.maxRuleChars) characters") }
        }
        if let a = req.area, !Learn.areas.contains(a) { throw ApiError("bad_request", "That isn't an area") }
    }

    public func playbook() async throws -> [LearnRule] { try with { sorted() } }

    public func addRule(_ req: LearnRuleRequest) async throws -> LearnRule {
        try with {
            try Self.check(req, partial: false)
            if rules.count >= Learn.maxRules { throw ApiError("bad_request", "The playbook holds \(Learn.maxRules) rules · delete some first") }
            next += 1
            let t = Self.now()
            let r = LearnRule(id: "rule_d\(next)", text: (req.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines), area: req.area ?? "other",
                              source: "owner", pinned: req.pinned ?? false, evidence: (req.evidence ?? []).map { var e = $0; e.at = e.at ?? t; return e },
                              createdAt: t, updatedAt: t)
            rules.append(r)
            return r
        }
    }

    public func patchRule(_ id: String, _ req: LearnRuleRequest) async throws -> LearnRule {
        _ = try LearnIds.rule(id)
        return try with {
            try Self.check(req, partial: true)
            guard let i = rules.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "That rule is gone") }
            if let t = req.text { rules[i].text = t.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let a = req.area { rules[i].area = a }
            if let e = req.evidence { rules[i].evidence = e.map { var x = $0; x.at = x.at ?? Self.now(); return x } }
            if let p = req.pinned { rules[i].pinned = p }
            rules[i].updatedAt = Self.now()
            return rules[i]
        }
    }

    public func deleteRule(_ id: String) async throws {
        _ = try LearnIds.rule(id)
        try with {
            guard rules.contains(where: { $0.id == id }) else { throw ApiError("not_found", "That rule is gone") }
            rules.removeAll { $0.id == id }
        }
    }

    public func lessons() async throws -> [LearnLesson] { try with { lessonList } }
    public func corrections(limit: Int) async throws -> [LearnCorrection] { try with { Array(correctionList.prefix(max(1, limit))) } }

    public func recipes(limit: Int) async throws -> [LearnRecipe] {
        try with { Array(library.sorted { $0.createdAt > $1.createdAt }.prefix(max(1, limit))).map { var r = $0; r.recipe = nil; return r } }
    }

    public func recipe(_ id: String) async throws -> LearnRecipe {
        _ = try LearnIds.recipe(id)
        return try with {
            guard let r = library.first(where: { $0.id == id }) else { throw ApiError("not_found", "That recipe is gone") }
            return r
        }
    }

    public func patchRecipe(_ id: String, _ patch: LearnRecipePatch) async throws -> LearnRecipe {
        _ = try LearnIds.recipe(id)
        return try with {
            guard let i = library.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "That recipe is gone") }
            if let n = patch.name {
                guard n.count <= 120 else { throw ApiError("bad_request", "A name is at most 120 characters") }
                library[i].name = n.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let tags = patch.tags {
                let clean = tags.compactMap(LearnFilter.cleanTag)
                guard clean.count <= Learn.maxTags else { throw ApiError("bad_request", "A recipe keeps at most \(Learn.maxTags) tags") }
                var seen = Set<String>()
                library[i].tags = clean.filter { seen.insert($0).inserted }
            }
            library[i].updatedAt = Self.now()
            return library[i]
        }
    }

    public func deleteRecipe(_ id: String) async throws {
        _ = try LearnIds.recipe(id)
        try with {
            guard library.contains(where: { $0.id == id }) else { throw ApiError("not_found", "That recipe is gone") }
            library.removeAll { $0.id == id }
        }
    }

    /// Closest by the same features the server compares (pacing, length, tempo), plus how many tags they share.
    public func nearest(recipeId: String, k: Int) async throws -> LearnNearest {
        _ = try LearnIds.recipe(recipeId)
        return try with {
            guard let me = library.first(where: { $0.id == recipeId }) else { throw ApiError("not_found", "That recipe isn't in the library") }
            let scale: [String: Double] = ["durationSec": 30, "shots": 10, "cutsPerMin": 40, "bpm": 60]
            func dist(_ o: LearnRecipe) -> Double {
                var sum = 0.0
                for (key, s) in scale {
                    let a = me.features[key] ?? 0, b = o.features[key] ?? 0
                    sum += pow((a - b) / s, 2)
                }
                let rms = (sum / Double(scale.count)).squareRoot()
                let ta = Set(me.tags), tb = Set(o.tags)
                let jac = ta.union(tb).isEmpty ? 1 : Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
                return ((rms + 0.5 * (1 - jac)) * 1000).rounded() / 1000
            }
            let near = library.filter { $0.id != recipeId }.map { o -> LearnRecipe in var x = o; x.distance = dist(o); x.recipe = nil; return x }
                .sorted { ($0.distance ?? 9) < ($1.distance ?? 9) }
            return LearnNearest(recipeId: recipeId, nearest: Array(near.prefix(max(1, k))))
        }
    }

    public func gaps(limit: Int) async throws -> [LearnGap] { try with { Array(gapList.prefix(max(1, limit))) } }

    /// Review mode: the playbook at its 200-rule limit ("Add rule" off).
    public func fillPlaybook() {
        lock.lock(); defer { lock.unlock() }
        let t = Self.now()
        while rules.count < Learn.maxRules {
            next += 1
            rules.append(LearnRule(id: "rule_d\(next)", text: "Rule \(rules.count + 1)", area: Learn.areas[rules.count % Learn.areas.count], createdAt: t, updatedAt: t))
        }
    }
}
