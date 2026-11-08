import Foundation

/// The learning editor (workstream 3, plans/api.md "Learning editor", `/v1/learn/*`, owner only): the playbook of rules
/// Claude follows, the lessons and corrections they come from, the recipe library (every analysed reference and every
/// finished edit) and the effects MUSE can't make yet. Screens: plans/learning-editor-ui.md. Every field the server may
/// leave out is optional and decoded leniently, so a newer server never breaks the screens.
public enum Learn {
    /// The server's areas, in the order the playbook groups them (Captions, Text, Pacing, Transitions, Look, Motion,
    /// Speed, Timing, Sound, Shape, Other).
    public static let areas = ["captions", "text", "pacing", "transition", "look", "motion", "speed", "timing", "audio", "ratio", "other"]
    /// The most rules a studio keeps, and the longest rule (the server's limits).
    public static let maxRules = 200
    public static let maxRuleChars = 300
    /// The rule editor shows its counter from this many characters.
    public static let counterFrom = 250
    /// Tag limits (the server's): 30 tags of 32 characters.
    public static let maxTags = 30
    public static let maxTagChars = 32
}

/// One piece of evidence for a rule: a correction, a post, a recipe or the owner's note.
public struct LearnEvidence: Codable, Hashable, Sendable {
    /// correction | post | recipe | note
    public var kind: String
    /// The correction's number, a post or recipe id (the server sends strings or numbers; kept as text).
    public var id: String?
    public var note: String
    public var at: Int64?

    public init(kind: String, id: String? = nil, note: String, at: Int64? = nil) {
        self.kind = kind; self.id = id; self.note = note; self.at = at
    }

    enum CodingKeys: String, CodingKey { case kind, id, note, at }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = c.o(.kind) ?? "note"
        if let s: String = c.o(.id) { id = s } else if let n: Int64 = c.o(.id) { id = String(n) } else { id = nil }
        note = c.o(.note) ?? ""
        at = c.o(.at)
    }
}

/// A playbook rule (`Rule` in plans/api.md).
public struct LearnRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var area: String
    /// owner | claude | learned
    public var source: String
    public var pinned: Bool
    public var evidence: [LearnEvidence]
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(id: String, text: String, area: String = "other", source: String = "owner", pinned: Bool = false, evidence: [LearnEvidence] = [],
                createdAt: Int64 = 0, updatedAt: Int64 = 0) {
        self.id = id; self.text = text; self.area = area; self.source = source; self.pinned = pinned; self.evidence = evidence
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, text, area, source, pinned, evidence, createdAt, updatedAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = c.o(.text) ?? ""
        area = c.o(.area) ?? "other"
        source = c.o(.source) ?? "owner"
        pinned = c.o(.pinned) ?? false
        evidence = c.o(.evidence) ?? []
        createdAt = c.o(.createdAt) ?? 0
        updatedAt = c.o(.updatedAt) ?? createdAt
    }
}

/// `POST /v1/learn/playbook` and `PATCH …/{id}`: only the fields set are sent.
public struct LearnRuleRequest: Encodable, Hashable, Sendable {
    public var text: String?
    public var area: String?
    public var evidence: [LearnEvidence]?
    public var pinned: Bool?
    public init(text: String? = nil, area: String? = nil, evidence: [LearnEvidence]? = nil, pinned: Bool? = nil) {
        self.text = text; self.area = area; self.evidence = evidence; self.pinned = pinned
    }
}

/// `GET /v1/learn/lessons`: corrections grouped by area and Claude's change, the most frequent first.
public struct LearnLesson: Codable, Hashable, Sendable, Identifiable {
    public var area: String
    public var claudeChange: String
    public var count: Int
    public var undos: Int
    public var last: Int64
    public var examples: [String]
    public var ids: [Int]
    public var id: String { "\(area)|\(claudeChange)" }

    public init(area: String, claudeChange: String = "", count: Int, undos: Int = 0, last: Int64 = 0, examples: [String] = [], ids: [Int] = []) {
        self.area = area; self.claudeChange = claudeChange; self.count = count; self.undos = undos; self.last = last; self.examples = examples; self.ids = ids
    }

    enum CodingKeys: String, CodingKey { case area, claudeChange, count, undos, last, examples, ids }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        area = c.o(.area) ?? "other"
        claudeChange = c.o(.claudeChange) ?? ""
        count = c.o(.count) ?? 0
        undos = c.o(.undos) ?? 0
        last = c.o(.last) ?? 0
        examples = c.o(.examples) ?? []
        ids = c.o(.ids) ?? []
    }
}

/// `GET /v1/learn/corrections`: the owner changing or undoing one of Claude's changes.
public struct LearnCorrection: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var sessionId: String?
    public var takeId: String?
    /// undo | change
    public var kind: String
    public var area: String
    /// Plain words: "Changed the look after Claude's “Look Film”".
    public var what: String
    public var createdAt: Int64

    public init(id: Int, sessionId: String? = nil, takeId: String? = nil, kind: String = "change", area: String = "other", what: String, createdAt: Int64 = 0) {
        self.id = id; self.sessionId = sessionId; self.takeId = takeId; self.kind = kind; self.area = area; self.what = what; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, sessionId, takeId, kind, area, what, createdAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        sessionId = c.o(.sessionId)
        takeId = c.o(.takeId)
        kind = c.o(.kind) ?? "change"
        area = c.o(.area) ?? "other"
        what = c.o(.what) ?? ""
        createdAt = c.o(.createdAt) ?? 0
    }
}

/// How a posted edit did, from Posts (fields the platforms didn't report are nil).
public struct LearnPerformance: Codable, Hashable, Sendable {
    public var posts: Int
    public var views: Int
    public var likes: Int
    public var comments: Int
    public var saves: Int?
    public var avgWatchSec: Double?
    /// 0–1.
    public var completion: Double?

    public init(posts: Int = 0, views: Int = 0, likes: Int = 0, comments: Int = 0, saves: Int? = nil, avgWatchSec: Double? = nil, completion: Double? = nil) {
        self.posts = posts; self.views = views; self.likes = likes; self.comments = comments; self.saves = saves; self.avgWatchSec = avgWatchSec; self.completion = completion
    }

    enum CodingKeys: String, CodingKey { case posts, views, likes, comments, saves, avgWatchSec, completion }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        posts = Self.int(c, .posts) ?? 0
        views = Self.int(c, .views) ?? 0
        likes = Self.int(c, .likes) ?? 0
        comments = Self.int(c, .comments) ?? 0
        saves = Self.int(c, .saves)
        avgWatchSec = c.o(.avgWatchSec)
        completion = c.o(.completion)
    }
    /// Counts arrive as JSON numbers; a sum of floats ("1200.0") still reads.
    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Int? {
        if let i: Int = c.o(k) { return i }
        return (c.o(k) as Double?).map { Int($0.rounded()) }
    }
}

/// A recipe in the library (`RecipeEntry`): an analysed reference or a finished edit. `recipe` comes with the detail only;
/// `distance` with nearest only.
public struct LearnRecipe: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// reference | edit
    public var origin: String
    public var referenceId: String?
    public var takeId: String?
    public var name: String
    public var summary: String
    public var tags: [String]
    public var features: [String: Double]
    public var performance: LearnPerformance?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var recipe: Recipe?
    /// Nearest only: 0 is the same.
    public var distance: Double?

    public var isReference: Bool { origin == "reference" }

    enum CodingKeys: String, CodingKey { case id, origin, referenceId, takeId, name, summary, tags, features, performance, createdAt, updatedAt, recipe, distance }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        origin = c.o(.origin) ?? "reference"
        referenceId = c.o(.referenceId)
        takeId = c.o(.takeId)
        name = c.o(.name) ?? ""
        summary = c.o(.summary) ?? ""
        tags = c.o(.tags) ?? []
        features = c.o(.features) ?? [:]
        performance = c.o(.performance)
        createdAt = c.o(.createdAt) ?? 0
        updatedAt = c.o(.updatedAt) ?? createdAt
        recipe = c.o(.recipe)
        distance = c.o(.distance)
    }

    /// Length in seconds: the recipe's, else the feature the server keeps for nearest.
    public var durationSec: Double? { recipe.map(\.durationSec).flatMap { $0 > 0 ? $0 : nil } ?? features["durationSec"] }
    /// Cuts between shots.
    public var cuts: Int? {
        if let r = recipe, !r.slots.isEmpty { return max(0, r.slots.count - 1) }
        return features["shots"].map { max(0, Int($0.rounded()) - 1) }
    }
}

/// `PATCH /v1/learn/recipes/{id}`.
public struct LearnRecipePatch: Encodable, Hashable, Sendable {
    public var name: String?
    public var tags: [String]?
    public init(name: String? = nil, tags: [String]? = nil) { self.name = name; self.tags = tags }
}

/// `GET /v1/learn/recipes/nearest`.
public struct LearnNearest: Codable, Hashable, Sendable {
    public var recipeId: String
    public var nearest: [LearnRecipe]
    enum CodingKeys: String, CodingKey { case recipeId, nearest }
    public init(recipeId: String, nearest: [LearnRecipe]) { self.recipeId = recipeId; self.nearest = nearest }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        recipeId = c.o(.recipeId) ?? ""
        nearest = c.o(.nearest) ?? []
    }
}

/// An effect recipes need that MUSE can't make yet (`Gap`), most requested first.
public struct LearnGap: Codable, Hashable, Sendable, Identifiable {
    public struct Example: Codable, Hashable, Sendable {
        public var recipeId: String?
        public var referenceId: String?
        public var atSec: Double?
        public var note: String
        public var at: Int64?
        enum CodingKeys: String, CodingKey { case recipeId, referenceId, atSec, note, at }
        public init(note: String, recipeId: String? = nil, at: Int64? = nil) { self.note = note; self.recipeId = recipeId; self.at = at }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            recipeId = c.o(.recipeId); referenceId = c.o(.referenceId); atSec = c.o(.atSec); note = c.o(.note) ?? ""; at = c.o(.at)
        }
    }
    public var key: String
    /// transition | effect | text | font | motion | other
    public var kind: String
    public var what: String
    public var count: Int
    public var examples: [Example]
    public var firstAt: Int64?
    public var lastAt: Int64?
    public var id: String { key }

    public init(key: String, kind: String, what: String, count: Int, examples: [Example] = [], lastAt: Int64? = nil) {
        self.key = key; self.kind = kind; self.what = what; self.count = count; self.examples = examples; self.lastAt = lastAt; self.firstAt = lastAt
    }

    enum CodingKeys: String, CodingKey { case key, kind, what, count, examples, firstAt, lastAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        kind = c.o(.kind) ?? "other"
        what = c.o(.what) ?? key
        count = c.o(.count) ?? 1
        examples = c.o(.examples) ?? []
        firstAt = c.o(.firstAt)
        lastAt = c.o(.lastAt)
    }
}

// MARK: Plain words

/// The screens' words (owner only, plain sentences, no jargon).
public enum LearnText {
    /// An area as a heading ("Transitions", "Sound").
    public static func area(_ a: String) -> String {
        switch a {
        case "captions": return "Captions"
        case "text": return "Text"
        case "pacing": return "Pacing"
        case "transition": return "Transitions"
        case "look": return "Look"
        case "motion": return "Motion"
        case "speed": return "Speed"
        case "timing": return "Timing"
        case "audio": return "Sound"
        case "ratio": return "Shape"
        default: return "Other"
        }
    }

    /// An area inside a sentence ("You changed Claude's look 4 times").
    public static func areaNoun(_ a: String) -> String {
        switch a {
        case "captions": return "captions"
        case "text": return "text"
        case "pacing": return "pacing"
        case "transition": return "transitions"
        case "look": return "look"
        case "motion": return "camera moves"
        case "speed": return "speed"
        case "timing": return "timing"
        case "audio": return "sound"
        case "ratio": return "shape"
        default: return "edits"
        }
    }

    /// A lesson in plain words: "You changed Claude's look 4 times", "You undid Claude's transitions twice".
    public static func sentence(_ l: LearnLesson) -> String {
        let verb = l.count > 0 && l.undos == l.count ? "undid" : "changed"
        return "You \(verb) Claude's \(areaNoun(l.area)) \(times(l.count))"
    }

    /// "once", "twice", "4 times".
    public static func times(_ n: Int) -> String {
        switch n {
        case ...1: return "once"
        case 2: return "twice"
        default: return "\(n) times"
        }
    }

    /// Who wrote a rule and its evidence, in words: "Yours", "From Claude · 3 corrections", "Learned · 2 posts".
    public static func byline(_ r: LearnRule) -> String {
        let corrections = r.evidence.filter { $0.kind == "correction" }.count
        let posts = r.evidence.filter { $0.kind == "post" }.count
        switch r.source {
        case "claude": return corrections > 0 ? "From Claude · \(count(corrections, "correction"))" : "From Claude"
        case "learned":
            if posts > 0 { return "Learned · \(count(posts, "post"))" }
            return corrections > 0 ? "Learned · \(count(corrections, "correction"))" : "Learned"
        default: return "Yours"
        }
    }

    /// "1 correction", "3 corrections".
    public static func count(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }

    /// One evidence line: "Correction · Changed the look after Claude's “Look Film” · 2 days ago".
    public static func evidence(_ e: LearnEvidence, now: Int64) -> String {
        let kind: String
        switch e.kind {
        case "correction": kind = "Correction"
        case "post": kind = "Post"
        case "recipe": kind = "Recipe"
        default: kind = "Note"
        }
        var parts = [kind]
        if !e.note.isEmpty { parts.append(e.note) }
        if let at = e.at, at > 0 { parts.append(relative(at, now: now).lowercasedFirst) }
        return parts.joined(separator: " · ")
    }

    /// "Just now", "5 min ago", "2 h ago", "Yesterday", "3 days ago", "Last week", "2 months ago".
    public static func relative(_ at: Int64, now: Int64) -> String {
        let m = max(0, (now - at) / 60_000)
        switch m {
        case ..<1: return "Just now"
        case ..<60: return "\(m) min ago"
        case ..<(24 * 60): return "\(m / 60) h ago"
        case ..<(48 * 60): return "Yesterday"
        case ..<(7 * 24 * 60): return "\(m / (24 * 60)) days ago"
        case ..<(14 * 24 * 60): return "Last week"
        case ..<(30 * 24 * 60): return "\(m / (7 * 24 * 60)) weeks ago"
        default:
            let months = max(1, m / (30 * 24 * 60))
            return months == 1 ? "Last month" : "\(months) months ago"
        }
    }

    /// The rule editor's counter, from 250 characters: "280 / 300". nil below.
    public static func counter(_ text: String) -> String? {
        text.count >= Learn.counterFrom ? "\(text.count) / \(Learn.maxRuleChars)" : nil
    }

    /// A big count: "860", "1.2k", "12k", "1.4M".
    public static func compact(_ n: Int) -> String {
        let v = Double(n)
        if n < 1000 { return "\(n)" }
        if n < 10_000 { return trim(String(format: "%.1f", v / 1000)) + "k" }
        if n < 1_000_000 { return "\(Int((v / 1000).rounded()))k" }
        return trim(String(format: "%.1f", v / 1_000_000)) + "M"
    }
    private static func trim(_ s: String) -> String { s.hasSuffix(".0") ? String(s.dropLast(2)) : s }

    /// The badge on a recipe's picture: "12 s · 9 cuts".
    public static func badge(_ r: LearnRecipe) -> String? {
        guard let d = r.durationSec, d > 0 else { return nil }
        let secs = "\(Int(d.rounded())) s"
        guard let c = r.cuts else { return secs }
        return "\(secs) · \(count(c, "cut"))"
    }

    /// The line under a tile: views for a posted edit ("1.2k views · 42% completion"), else the summary.
    public static func tileCaption(_ r: LearnRecipe) -> String {
        if let p = r.performance, p.posts > 0 {
            var s = "\(compact(p.views)) views"
            if let c = p.completion { s += " · \(Int((c * 100).rounded()))% completion" }
            return s
        }
        return r.summary
    }

    /// Where a recipe came from, in words.
    public static func origin(_ r: LearnRecipe) -> String { r.isReference ? "Reference" : "Your edit" }

    /// "Very close" (< 0.3), "Close" (< 0.6), else "Different".
    public static func closeness(_ distance: Double?) -> String {
        guard let d = distance else { return "Different" }
        return d < 0.3 ? "Very close" : d < 0.6 ? "Close" : "Different"
    }

    /// The shape of the edit in values with units: "9 shots · 27 cuts/min · 120 bpm · 3 text items".
    public static func shape(_ r: Recipe) -> String {
        var parts: [String] = []
        let shots = r.pacing?.shots ?? r.slots.count
        if shots > 0 { parts.append(count(shots, "shot")) }
        if let c = r.pacing?.cutsPerMin, c > 0 { parts.append("\(Int(c.rounded())) cuts/min") }
        if let b = r.sound?.bpm, b > 0 { parts.append("\(Int(b.rounded())) bpm") }
        if !r.text.isEmpty { parts.append(count(r.text.count, "text item")) }
        return parts.joined(separator: " · ")
    }

    /// Performance as value pairs, leaving out what wasn't reported: ("Views", "1.2k"), ("Avg watch", "6.5 s")…
    public static func performance(_ p: LearnPerformance) -> [(String, String)] {
        var out: [(String, String)] = [("Views", compact(p.views)), ("Likes", compact(p.likes))]
        if let s = p.saves { out.append(("Saves", compact(s))) }
        if let w = p.avgWatchSec { out.append(("Avg watch", String(format: "%.1f s", w))) }
        if let c = p.completion { out.append(("Completion", "\(Int((c * 100).rounded()))%")) }
        out.append(("Posts", "\(p.posts)"))
        return out
    }

    /// A gap's line: "Unknown transition · 4 references", "Lens flare · asked once".
    public static func gap(_ g: LearnGap) -> String {
        // Asked for directly (Claude or the owner): the server files those under an "ask_…" recipe id.
        let asked = !g.examples.isEmpty && g.examples.allSatisfy { $0.recipeId?.hasPrefix("ask_") ?? false }
        let how = asked ? "asked \(times(g.count))" : count(g.count, "reference")
        return "\(g.what) · \(how)"
    }

    /// The Phosphor icon for a transition on the shape strip (nil for a plain cut).
    public static func transitionIcon(_ kind: String) -> String? {
        switch kind {
        case "cut": return nil
        case "crossfade", "fade": return "intersect"
        case "whip": return "wind"
        case "flash": return "lightning"
        case "zoom": return "arrows-out-simple"
        case "glitch": return "waves"
        default: return "question"
        }
    }
}

// MARK: Filtering (the same rules as the server's `GET /v1/learn/recipes`)

public enum LearnOrigin: String, CaseIterable, Sendable { case all, reference, edit }
public enum LearnSort: String, CaseIterable, Sendable { case newest, mostViewed }

public enum LearnFilter {
    /// Search words match the name, summary and tags (all of them); every chosen tag must be present; then the order.
    public static func apply(_ list: [LearnRecipe], query: String, origin: LearnOrigin, tags: [String], sort: LearnSort) -> [LearnRecipe] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var out = list.filter { r in
            if origin != .all && r.origin != origin.rawValue { return false }
            if !words.isEmpty {
                let hay = "\(r.name) \(r.summary) \(r.tags.joined(separator: " "))".lowercased()
                if !words.allSatisfy({ hay.contains($0) }) { return false }
            }
            return tags.allSatisfy { r.tags.contains($0.lowercased()) }
        }
        switch sort {
        case .newest: out.sort { $0.createdAt > $1.createdAt }
        case .mostViewed: out.sort { ($0.performance?.views ?? -1, $0.createdAt) > ($1.performance?.views ?? -1, $1.createdAt) }
        }
        return out
    }

    /// The most-used tags (at most `limit`), leaving out the two that only repeat the origin.
    public static func topTags(_ list: [LearnRecipe], limit: Int = 8) -> [String] {
        var n: [String: Int] = [:]
        for r in list { for t in Set(r.tags) where t != "reference" && t != "own-edit" { n[t, default: 0] += 1 } }
        return n.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    /// A tag as the server stores it: trimmed, lower case, at most 32 characters. nil when empty.
    public static func cleanTag(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? nil : String(t.prefix(Learn.maxTagChars))
    }

    /// The playbook grouped by area in the screen's order (pinned first inside each group, as the server sorts them).
    public static func grouped(_ rules: [LearnRule]) -> [LearnRuleGroup] {
        Learn.areas.compactMap { a in
            let r = rules.filter { (Learn.areas.contains($0.area) ? $0.area : "other") == a }
            guard !r.isEmpty else { return nil }
            return LearnRuleGroup(area: a, rules: r.filter(\.pinned) + r.filter { !$0.pinned })
        }
    }
}

/// One area's rules on the Playbook.
public struct LearnRuleGroup: Identifiable, Hashable, Sendable {
    public var area: String
    public var rules: [LearnRule]
    public var id: String { area }
}

extension String {
    var lowercasedFirst: String {
        guard let f = first else { return self }
        // "Yesterday" → "yesterday" inside a line; numbers stay.
        return f.lowercased() + dropFirst()
    }
}
