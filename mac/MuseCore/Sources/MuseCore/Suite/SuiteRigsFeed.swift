import Foundation

// AI suite (workstream 1, build step 2; plans/api.md "The new Suite's server pieces"): the composer's draft stored with each
// job and photo ("Reuse settings"), saved rigs, a model's default rig, and the takes feed (the new Suite's rail). Server:
// server/api/src/suite/drafts.ts, rigs.ts and feed.ts. Wire types and pure rules only; the calls are on MuseAPI.

// MARK: Rig

/// One of a rig's optional moves (applied as a `#` chip). `intensity` 0–1.
public struct SuiteRigMove: Codable, Hashable, Sendable {
    public var id: String
    public var intensity: Double?

    public init(id: String, intensity: Double? = nil) {
        self.id = id
        self.intensity = intensity
    }

    enum CodingKeys: String, CodingKey { case id, intensity }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        intensity = c.o(.intensity)
    }
}

/// A rig: the composer's rig rows by catalog id, named as in `ComposerSettings`. Every field is optional; a missing field
/// is Auto. The server refuses unknown fields and accepts missing ones, so nil fields are left out of the JSON.
public struct SuiteRig: Codable, Hashable, Sendable {
    public var body: String?
    public var lens: String?
    /// 8–200 mm.
    public var focalMm: Double?
    public var aperture: String?
    public var height: String?
    public var shotSize: String?
    public var lighting: String?
    public var palette: String?
    public var stock: String?
    /// Grade the take with the Look (false = only describe it in the prompt).
    public var gradeLook: Bool?
    public var genre: String?
    public var era: String?
    public var tempo: String?
    public var format: String?
    /// At most 2, applied as `#` chips.
    public var moves: [SuiteRigMove]?

    public static let maxMoves = 2
    public static let focalRange: ClosedRange<Double> = 8...200

    public init(body: String? = nil, lens: String? = nil, focalMm: Double? = nil, aperture: String? = nil, height: String? = nil, shotSize: String? = nil,
                lighting: String? = nil, palette: String? = nil, stock: String? = nil, gradeLook: Bool? = nil, genre: String? = nil, era: String? = nil,
                tempo: String? = nil, format: String? = nil, moves: [SuiteRigMove]? = nil) {
        self.body = body
        self.lens = lens
        self.focalMm = focalMm
        self.aperture = aperture
        self.height = height
        self.shotSize = shotSize
        self.lighting = lighting
        self.palette = palette
        self.stock = stock
        self.gradeLook = gradeLook
        self.genre = genre
        self.era = era
        self.tempo = tempo
        self.format = format
        self.moves = moves
    }

    enum CodingKeys: String, CodingKey {
        case body, lens, focalMm, aperture, height, shotSize, lighting, palette, stock, gradeLook, genre, era, tempo, format, moves
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        body = c.o(.body)
        lens = c.o(.lens)
        focalMm = c.o(.focalMm)
        aperture = c.o(.aperture)
        height = c.o(.height)
        shotSize = c.o(.shotSize)
        lighting = c.o(.lighting)
        palette = c.o(.palette)
        stock = c.o(.stock)
        gradeLook = c.o(.gradeLook)
        genre = c.o(.genre)
        era = c.o(.era)
        tempo = c.o(.tempo)
        format = c.o(.format)
        moves = c.o(.moves)
    }
    // Encoding is synthesized: optionals are encoded only when set.

    /// Every row Auto (the server stores `{}` as no default rig). An empty `moves` list still counts as set, as on the server.
    public var isEmpty: Bool { self == SuiteRig() }

    /// The rig as the composer's chips (moves aside: they are `#` chips in the prompt). A missing `gradeLook` is on.
    public var settings: ComposerSettings {
        ComposerSettings(body: body, lens: lens, focalMm: focalMm, aperture: aperture, height: height, shotSize: shotSize, genre: genre, era: era,
                         tempo: tempo, palette: palette, stock: stock, gradeLook: gradeLook ?? true, lighting: lighting, format: format)
    }

    /// The composer's chips as a rig (the preset it started from is not part of a rig). `gradeLook` is stored only when
    /// it is off, since on is the default.
    public init(_ s: ComposerSettings, moves: [SuiteRigMove]? = nil) {
        self.init(body: s.body, lens: s.lens, focalMm: s.focalMm, aperture: s.aperture, height: s.height, shotSize: s.shotSize, lighting: s.lighting,
                  palette: s.palette, stock: s.stock, gradeLook: s.gradeLook ? nil : false, genre: s.genre, era: s.era, tempo: s.tempo, format: s.format,
                  moves: moves)
    }

    /// The server's check (suite/drafts.ts RigSchema) against a camera catalog: every id must be one of its options (hidden
    /// and merged ids included), focal 8–200 mm, at most 2 moves with intensity 0–1. nil = fine; otherwise the message,
    /// worded like the server's ("rig.lens: unknown lens \"x\""). `field` is the body key ("rig", "defaultRig").
    public func problem(in cat: CameraCatalog, field: String = "rig") -> String? {
        func ids(_ l: [SuiteOption]) -> Set<String> { Set(l.map(\.id)) }
        let rows: [(String, String?, String, Set<String>)] = [
            ("body", body, "camera body", ids(cat.bodies)),
            ("lens", lens, "lens", ids(cat.lenses)),
            ("aperture", aperture, "aperture", ids(cat.apertures)),
            ("height", height, "angle", ids(cat.heights)),
            ("shotSize", shotSize, "framing", ids(cat.shotSizes)),
            ("lighting", lighting, "lighting", ids(cat.lighting)),
            ("palette", palette, "palette", ids(cat.palettes)),
            ("stock", stock, "film stock", ids(cat.looks)),
            ("genre", genre, "genre", ids(cat.genres)),
            ("era", era, "era", ids(cat.eras)),
            ("tempo", tempo, "tempo", ids(cat.tempos)),
            ("format", format, "format", ids(cat.ugcFormats)),
        ]
        for (key, value, what, ok) in rows {
            if let v = value, !ok.contains(v) { return "\(field).\(key): unknown \(what) \"\(v)\"" }
        }
        if let f = focalMm, !Self.focalRange.contains(f) { return "\(field).focalMm: focal length is 8–200 mm" }
        if let list = moves {
            if list.count > Self.maxMoves { return "\(field).moves: at most \(Self.maxMoves) moves" }
            let known = Set(cat.moves.map(\.id)).union(cat.library.map(\.id))
            for (i, m) in list.enumerated() {
                if !known.contains(m.id) { return "\(field).moves.\(i).id: unknown move \"\(m.id)\"" }
                if let k = m.intensity, !(0...1).contains(k) { return "\(field).moves.\(i).intensity: 0–1" }
            }
        }
        return nil
    }
}

/// The model default rig rule (plans/api.md "Model default rig", client rule): when a model is @-mentioned, fill only the
/// rig rows still on Auto (nil) from her default rig; never overwrite a row the user set. `gradeLook` follows the Look: it
/// is taken only while the Look (palette and film stock) is still Auto and grading is at its default (on). Moves are not
/// applied here (they become `#` chips only if the prompt has no move yet). Returns the new settings and the names of the
/// rows it filled, in the rig's field order (empty: nothing applied, so no "Applied …'s rig · Undo").
public func applyDefaultRig(_ rig: SuiteRig, to settings: ComposerSettings) -> (ComposerSettings, filled: [String]) {
    var s = settings
    var filled: [String] = []
    func fill<T>(_ name: String, _ path: WritableKeyPath<ComposerSettings, T?>, _ value: T?) {
        guard s[keyPath: path] == nil, let v = value else { return }
        s[keyPath: path] = v
        filled.append(name)
    }
    let lookWasAuto = settings.palette == nil && settings.stock == nil
    fill("body", \.body, rig.body)
    fill("lens", \.lens, rig.lens)
    fill("focalMm", \.focalMm, rig.focalMm)
    fill("aperture", \.aperture, rig.aperture)
    fill("height", \.height, rig.height)
    fill("shotSize", \.shotSize, rig.shotSize)
    fill("lighting", \.lighting, rig.lighting)
    fill("palette", \.palette, rig.palette)
    fill("stock", \.stock, rig.stock)
    if let g = rig.gradeLook, lookWasAuto, settings.gradeLook, g != settings.gradeLook {
        s.gradeLook = g
        filled.append("gradeLook")
    }
    fill("genre", \.genre, rig.genre)
    fill("era", \.era, rig.era)
    fill("tempo", \.tempo, rig.tempo)
    fill("format", \.format, rig.format)
    return (s, filled)
}

/// A saved rig as GET /v1/suite/rigs returns it. `mine`: the signed-in user's own (the owner sees everyone's).
public struct SuiteRigView: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var rig: SuiteRig
    public var userId: String
    public var mine: Bool
    public var createdAt: Int64
    public var updatedAt: Int64

    /// At most this many rigs per person (`409 too_many_rigs`).
    public static let maxPerUser = 100
    /// A rig's name, trimmed: 1–60 characters.
    public static let maxName = 60

    public init(id: String, name: String, rig: SuiteRig, userId: String, mine: Bool, createdAt: Int64, updatedAt: Int64) {
        self.id = id
        self.name = name
        self.rig = rig
        self.userId = userId
        self.mine = mine
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, name, rig, userId, mine, createdAt, updatedAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.v(.name, "")
        rig = c.v(.rig, SuiteRig())
        userId = c.v(.userId, "")
        mine = c.v(.mine, false)
        createdAt = SuiteTime.ms(c, .createdAt)
        updatedAt = SuiteTime.ms(c, .updatedAt)
    }

    /// The name as the server stores it (trimmed), or the message it refuses it with.
    public static func cleanName(_ raw: String) -> Result<String, ApiError> {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return .failure(ApiError("bad_request", "Give the rig a name")) }
        if n.utf16.count > maxName { return .failure(ApiError("bad_request", "name: String must contain at most \(maxName) character(s)")) }
        return .success(n)
    }
}

/// POST /v1/suite/rigs
public struct NewSuiteRig: Codable, Hashable, Sendable {
    public var name: String
    public var rig: SuiteRig
    public init(name: String, rig: SuiteRig) {
        self.name = name
        self.rig = rig
    }
}

/// PATCH /v1/suite/rigs/{id}: nil fields are left out (unchanged). `rig` replaces the whole rig.
public struct SuiteRigPatch: Codable, Hashable, Sendable {
    public var name: String?
    public var rig: SuiteRig?
    public init(name: String? = nil, rig: SuiteRig? = nil) {
        self.name = name
        self.rig = rig
    }
}

/// PATCH /v1/models/{id} {defaultRig}: always sends the key, `null` to clear.
struct DefaultRigPatch: Encodable {
    var defaultRig: SuiteRig?
    enum CodingKeys: String, CodingKey { case defaultRig }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        if let r = defaultRig { try c.encode(r, forKey: .defaultRig) } else { try c.encodeNil(forKey: .defaultRig) }
    }
}

/// Server times are milliseconds; older or hand-written replies may send them as doubles.
enum SuiteTime {
    static func ms<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int64 {
        if let v: Int64 = c.o(key) { return v }
        if let d: Double = c.o(key), d.isFinite, abs(d) < 9e15 { return Int64(d) }
        return 0
    }
}

// MARK: Draft

/// The composer's full draft, as the client sent it (server suite/drafts.ts DraftSchema). Stored with each job and photo and
/// returned as `Job.draft` / `Take.draft`, so "Reuse settings" restores the composer exactly. Every key is kept, known or
/// not (a newer app's fields survive an older one), so encoding gives back exactly what was decoded. The known fields are
/// read and written through the accessors; setting one to nil removes its key.
public struct SuiteDraft: Codable, Hashable, Sendable {
    /// The composer's tools plus `upscale` (only the feed names it).
    public static let tools = ["shot", "photo", "storyboard", "swap", "recast", "extend", "upscale", "talking", "ugc"]
    /// The keys the server reads or checks; everything else is `extra`.
    public static let knownKeys: Set<String> = ["v", "tool", "quality", "aspect", "duration", "takes", "count", "sound", "speaking", "rig", "tokens", "slots"]
    public static let maxBytes = 64 * 1024
    public static let maxTokens = 400

    /// Every key exactly as sent.
    public var raw: [String: JSONValue]

    public init(raw: [String: JSONValue]) { self.raw = raw }

    public init(tool: String, v: Int = 1, quality: String? = nil, aspect: String? = nil, duration: Double? = nil, takes: Int? = nil, count: Int? = nil,
                sound: Bool? = nil, speaking: Bool? = nil, rig: SuiteRig? = nil, tokens: [JSONValue]? = nil, slots: JSONValue? = nil,
                extra: [String: JSONValue] = [:]) {
        raw = extra.filter { !SuiteDraft.knownKeys.contains($0.key) }
        self.v = v
        self.tool = tool
        self.quality = quality
        self.aspect = aspect
        self.duration = duration
        self.takes = takes
        self.count = count
        self.sound = sound
        self.speaking = speaking
        self.rig = rig
        self.tokens = tokens
        self.slots = slots
    }

    public init(from d: Decoder) throws {
        raw = try d.singleValueContainer().decode([String: JSONValue].self)
    }

    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        try c.encode(raw)
    }

    private func string(_ k: String) -> String? {
        if case .string(let s)? = raw[k] { return s }
        return nil
    }
    private func number(_ k: String) -> Double? {
        if case .number(let n)? = raw[k] { return n }
        return nil
    }
    private func int(_ k: String) -> Int? {
        guard let n = number(k), n.isFinite, abs(n) < 1e15 else { return nil }
        return Int(n)
    }
    private func bool(_ k: String) -> Bool? {
        if case .bool(let b)? = raw[k] { return b }
        return nil
    }

    /// The draft format's version (default 1).
    public var v: Int {
        get { int("v") ?? 1 }
        set { raw["v"] = .number(Double(newValue)) }
    }
    /// shot | photo | storyboard | swap | recast | extend | upscale | talking | ugc ("" when missing).
    public var tool: String {
        get { string("tool") ?? "" }
        set { raw["tool"] = .string(newValue) }
    }
    public var quality: String? {
        get { string("quality") }
        set { raw["quality"] = newValue.map(JSONValue.string) }
    }
    public var aspect: String? {
        get { string("aspect") }
        set { raw["aspect"] = newValue.map(JSONValue.string) }
    }
    /// Seconds.
    public var duration: Double? {
        get { number("duration") }
        set { raw["duration"] = newValue.map(JSONValue.number) }
    }
    public var takes: Int? {
        get { int("takes") }
        set { raw["takes"] = newValue.map { JSONValue.number(Double($0)) } }
    }
    /// Photos in the run.
    public var count: Int? {
        get { int("count") }
        set { raw["count"] = newValue.map { JSONValue.number(Double($0)) } }
    }
    public var sound: Bool? {
        get { bool("sound") }
        set { raw["sound"] = newValue.map(JSONValue.bool) }
    }
    /// true, false, or nil = auto (sent as `null` or left out).
    public var speaking: Bool? {
        get { bool("speaking") }
        set { raw["speaking"] = newValue.map(JSONValue.bool) }
    }
    /// The rig rows, typed. Unknown keys inside the rig are only kept through `raw["rig"]`.
    public var rig: SuiteRig? {
        get { raw["rig"].flatMap { SuiteJSON.decode($0, as: SuiteRig.self) } }
        set { raw["rig"] = newValue.flatMap { SuiteJSON.value($0) } }
    }
    /// The prompt's tokens with their chip keys, as the client wrote them.
    public var tokens: [JSONValue]? {
        get {
            if case .array(let a)? = raw["tokens"] { return a }
            return nil
        }
        set { raw["tokens"] = newValue.map(JSONValue.array) }
    }
    /// The input slots, as the client wrote them.
    public var slots: JSONValue? {
        get { raw["slots"] }
        set { raw["slots"] = newValue }
    }
    /// The keys the server doesn't read, kept as sent.
    public var extra: [String: JSONValue] {
        get { raw.filter { !SuiteDraft.knownKeys.contains($0.key) } }
        set {
            raw = raw.filter { SuiteDraft.knownKeys.contains($0.key) }
            for (k, v) in newValue where !SuiteDraft.knownKeys.contains(k) { raw[k] = v }
        }
    }

    /// What the server refuses ("Invalid draft: …" without the prefix), or nil.
    public var problem: String? {
        guard let t = string("tool") else { return "tool: Required" }
        if !SuiteDraft.tools.contains(t) { return "tool: unknown tool \"\(t)\"" }
        for k in ["quality", "aspect"] where raw[k] != nil && string(k) == nil { return "\(k): Expected string" }
        if raw["duration"] != nil {
            guard let d = number("duration"), (0...120).contains(d) else { return "duration: 0–120 seconds" }
        }
        for k in ["takes", "count"] where raw[k] != nil {
            guard let n = number(k), n == n.rounded(), (1...8).contains(n) else { return "\(k): a whole number 1–8" }
        }
        if raw["v"] != nil {
            guard let n = number("v"), n == n.rounded(), (1...99).contains(n) else { return "v: a whole number 1–99" }
        }
        if raw["sound"] != nil && bool("sound") == nil { return "sound: Expected boolean" }
        if let s = raw["speaking"], s != .null, bool("speaking") == nil { return "speaking: Expected boolean" }
        if let r = raw["rig"] {
            guard case .object = r else { return "rig: Expected object" }
        }
        if let t = raw["tokens"] {
            guard case .array(let a) = t else { return "tokens: Expected array" }
            if a.count > SuiteDraft.maxTokens { return "tokens: at most \(SuiteDraft.maxTokens)" }
        }
        if let d = try? JSONEncoder().encode(self), d.count > SuiteDraft.maxBytes { return "a draft is at most \(SuiteDraft.maxBytes / 1024) KB" }
        return nil
    }
}

/// JSON value ↔ Codable type, through JSON (the rig inside a draft).
enum SuiteJSON {
    static func value<T: Encodable>(_ x: T) -> JSONValue? {
        guard let d = try? JSONEncoder().encode(x) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: d)
    }
    static func decode<T: Decodable>(_ v: JSONValue, as type: T.Type) -> T? {
        guard let d = try? JSONEncoder().encode(v) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

// MARK: Feed

/// One card in the new Suite's takes rail (GET /v1/suite/feed). `kind`: job (queued, running or failed: one card per job),
/// take (a finished video take) or photo (a still). Member-safe: no providers or engine names; `label` is the tier label.
public struct SuiteFeedItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// job | take | photo
    public var kind: String
    /// queued | running | failed | done
    public var status: String
    /// shot | photo | storyboard | swap | recast | extend | upscale | talking | ugc
    public var tool: String
    public var jobId: String?
    public var title: String
    public var modelId: String?
    public var modelName: String?
    public var createdAt: Int64
    public var poster: ImageRef?
    public var aspect: String?
    public var durationSec: Double?
    public var price: Double
    /// The caption line: "9:16, 10 s, 1 take, sound on" / "9:16, 4 photos".
    public var summary: String
    // job
    public var progress: Double?
    public var phase: String?
    /// Running only.
    public var secondsLeft: Double?
    public var blocked: String?
    /// Failed only: why, and the code (never shown).
    public var error: String?
    public var errorCode: String?
    public var refunded: Double?
    /// The tier label ("Shot · Draft · 768p"); takes and photos: the take's label.
    public var label: String?
    /// Takes the job makes.
    public var takes: Int?
    // take and photo
    public var takeId: String?
    /// Video takes only.
    public var videoUrl: String?
    public var index: Int?
    public var of: Int?
    /// Marked final.
    public var isFinal: Bool

    public init(id: String, kind: String, status: String, tool: String, jobId: String? = nil, title: String = "", modelId: String? = nil,
                modelName: String? = nil, createdAt: Int64 = 0, poster: ImageRef? = nil, aspect: String? = nil, durationSec: Double? = nil, price: Double = 0,
                summary: String = "", isFinal: Bool = false) {
        self.id = id
        self.kind = kind
        self.status = status
        self.tool = tool
        self.jobId = jobId
        self.title = title
        self.modelId = modelId
        self.modelName = modelName
        self.createdAt = createdAt
        self.poster = poster
        self.aspect = aspect
        self.durationSec = durationSec
        self.price = price
        self.summary = summary
        self.isFinal = isFinal
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, status, tool, jobId, title, modelId, modelName, createdAt, poster, aspect, durationSec, price, summary
        case progress, phase, secondsLeft, blocked, error, errorCode, refunded, label, takes
        case takeId, videoUrl, index, of
        case isFinal = "final"
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let k: String = c.v(.kind, "job")
        kind = k
        status = c.v(.status, k == "job" ? "queued" : "done")
        tool = c.v(.tool, k == "photo" ? "photo" : "shot")
        jobId = c.o(.jobId)
        title = c.v(.title, "")
        modelId = c.o(.modelId)
        modelName = c.o(.modelName)
        createdAt = SuiteTime.ms(c, .createdAt)
        poster = c.o(.poster)
        aspect = c.o(.aspect)
        durationSec = c.o(.durationSec)
        price = c.v(.price, 0)
        summary = c.v(.summary, "")
        progress = c.o(.progress)
        phase = c.o(.phase)
        secondsLeft = c.o(.secondsLeft)
        blocked = c.o(.blocked)
        error = c.o(.error)
        errorCode = c.o(.errorCode)
        refunded = c.o(.refunded)
        label = c.o(.label)
        takes = c.o(.takes)
        takeId = c.o(.takeId)
        videoUrl = c.o(.videoUrl)
        index = c.o(.index)
        of = c.o(.of)
        isFinal = c.v(.isFinal, false)
    }

    public var isJob: Bool { kind == "job" }
    public var isPhoto: Bool { kind == "photo" }
    public var isVideoTake: Bool { kind == "take" }
    public var isFailed: Bool { status == "failed" }
    /// Queued or running.
    public var isActive: Bool { status == "queued" || status == "running" }
}

/// GET /v1/suite/feed → a page. Pass `nextCursor` back until it is nil.
public struct SuiteFeedPage: Codable, Hashable, Sendable {
    public var items: [SuiteFeedItem]
    public var nextCursor: String?
    /// The first page only (no cursor, no collection): the "Queued" group above the items (build step 3).
    public var queued: [QueuedShot]

    public init(items: [SuiteFeedItem] = [], nextCursor: String? = nil, queued: [QueuedShot] = []) {
        self.items = items
        self.nextCursor = nextCursor
        self.queued = queued
    }

    enum CodingKeys: String, CodingKey { case items, nextCursor, queued }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        items = c.v(.items, [])
        nextCursor = c.o(.nextCursor)
        queued = c.v(.queued, [])
    }
}

/// GET /v1/suite/feed?tool=&status=&model=&cursor=&limit=. Lists go as comma lists; empty values are left out.
public struct SuiteFeedQuery: Hashable, Sendable {
    public static let statuses = ["queued", "running", "failed", "done"]
    public static let defaultLimit = 30
    public static let maxLimit = 60

    public var tool: [String]
    public var status: [String]
    public var model: String?
    public var cursor: String?
    public var limit: Int?
    /// One Library collection's takes and photos only (no pending jobs, no queue).
    public var collection: String?

    public init(tool: [String] = [], status: [String] = [], model: String? = nil, cursor: String? = nil, limit: Int? = nil, collection: String? = nil) {
        self.tool = tool
        self.status = status
        self.model = model
        self.cursor = cursor
        self.limit = limit
        self.collection = collection
    }

    /// The same query for the next page.
    public func next(_ cursor: String?) -> SuiteFeedQuery {
        var q = self
        q.cursor = cursor
        return q
    }

    /// "tool=shot,photo&status=done&model=m_1&cursor=…&limit=10" (no leading "?"; "" with nothing set).
    public var queryString: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        func list(_ l: [String]) -> String? {
            let xs = l.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return xs.isEmpty ? nil : xs.map(enc).joined(separator: ",")
        }
        var parts: [String] = []
        if let t = list(tool) { parts.append("tool=" + t) }
        if let s = list(status) { parts.append("status=" + s) }
        if let m = model, !m.isEmpty { parts.append("model=" + enc(m)) }
        if let c = cursor, !c.isEmpty { parts.append("cursor=" + enc(c)) }
        if let l = limit { parts.append("limit=\(l)") }
        if let c = collection, !c.isEmpty { parts.append("collection=" + enc(c)) }
        return parts.joined(separator: "&")
    }

    /// "v1/suite/feed" plus the query.
    public var path: String {
        let q = queryString
        return q.isEmpty ? "v1/suite/feed" : "v1/suite/feed?" + q
    }
}

/// The feed's wording rules, shared with the demo (server suite/drafts.ts draftSummary and aspectOf).
public enum SuiteFeedText {
    /// "10 s", "7.5 s".
    static func secs(_ n: Double) -> String {
        let r = n == n.rounded() ? n : (n * 10).rounded() / 10
        return r == r.rounded() && abs(r) < 1e15 ? "\(Int64(r)) s" : "\(r) s"
    }

    /// The caption line: "9:16, 10 s, 1 take, sound on"; photos "9:16, 4 photos". The draft's values win; the fallbacks
    /// come from the request or the file.
    public static func summary(_ d: SuiteDraft?, aspect: String? = nil, seconds: Double? = nil, takes: Int? = nil, count: Int? = nil, sound: Bool? = nil) -> String {
        var parts: [String] = []
        if let a = d?.aspect ?? aspect { parts.append(a) }
        let tool = d.map(\.tool).flatMap { $0.isEmpty ? nil : $0 }
        if tool == "photo" || (tool == nil && (count ?? 0) != 0) {
            if let n = d?.count ?? count, n != 0 { parts.append("\(n) photo\(n == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }
        if let s = d?.duration ?? seconds, s != 0, !s.isNaN { parts.append(secs(s)) }
        if let t = d?.takes ?? takes, t != 0 { parts.append("\(t) take\(t == 1 ? "" : "s")") }
        if let on = d?.sound ?? sound { parts.append(on ? "sound on" : "sound off") }
        return parts.joined(separator: ", ")
    }

    /// The closest of the composer's shapes for a picture size ("9:16"), or nil.
    public static func aspect(width: Double?, height: Double?) -> String? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        let shapes: [(String, Double)] = [("9:16", 9.0 / 16), ("16:9", 16.0 / 9), ("1:1", 1), ("4:5", 4.0 / 5), ("3:4", 3.0 / 4), ("4:3", 4.0 / 3), ("21:9", 21.0 / 9), ("2:3", 2.0 / 3)]
        let r = w / h
        var best = shapes[0]
        for s in shapes.dropFirst() where abs(log(s.1 / r)) < abs(log(best.1 / r)) { best = s }
        return best.0
    }
}

/// The feed's opaque cursor: the last item's (createdAt, id), as base64url JSON like the server's.
enum SuiteFeedCursor {
    static func encode(_ createdAt: Int64, _ id: String) -> String {
        let v: [JSONValue] = [.number(Double(createdAt)), .string(id)]
        let d = (try? JSONEncoder().encode(v)) ?? Data()
        return d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> (Int64, String)? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let v = try? JSONDecoder().decode([JSONValue].self, from: d), v.count == 2,
              case .number(let n) = v[0], case .string(let id) = v[1], n.isFinite, abs(n) < 9e15 else { return nil }
        return (Int64(n), id)
    }
}
