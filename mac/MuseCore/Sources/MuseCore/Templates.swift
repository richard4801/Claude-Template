import Foundation

// Photo templates (plans/templates.md, contract in plans/api.md "Photo templates"): a reusable look (style, scene, camera,
// light, grade, after-effects and a variation pool) applied to any model and outfit. The layers stay on the server: only the
// template's owner ever receives `layers` and `variationPool`; everyone else sees the template as one locked line,
// "Template: Mirror selfie", and the server builds the final prompt.

/// "none" | "phone-natural" | "underexposed" | "moody-blue" | "golden" | "harsh-sun" | "faded" | "mono"
public enum TemplateGrade: String, CaseIterable, Codable, Sendable {
    case none, phoneNatural = "phone-natural", underexposed, moodyBlue = "moody-blue", golden, harshSun = "harsh-sun", faded, mono
    public var label: String {
        switch self {
        case .none: return "None"
        case .phoneNatural: return "Phone-natural"
        case .underexposed: return "Underexposed"
        case .moodyBlue: return "Moody blue"
        case .golden: return "Golden"
        case .harshSun: return "Harsh sun"
        case .faded: return "Faded"
        case .mono: return "Mono"
        }
    }
}

/// Applied by the server to each generated still after the image engine (an edit step, not prompt words).
public struct TemplateAfterEffects: Codable, Hashable, Sendable {
    /// 0–1; nil or 0 = off.
    public var faceMotionBlur: Double?
    /// Degrees; 0 = a sideways drag.
    public var blurAngle: Double?
    /// A `TemplateGrade` raw value.
    public var grade: String?
    /// 0–1.
    public var grain: Double?

    public init(faceMotionBlur: Double? = nil, blurAngle: Double? = nil, grade: String? = nil, grain: Double? = nil) {
        self.faceMotionBlur = faceMotionBlur
        self.blurAngle = blurAngle
        self.grade = grade
        self.grain = grain
    }

    public var isEmpty: Bool { (faceMotionBlur ?? 0) == 0 && (grain ?? 0) == 0 && (grade == nil || grade == TemplateGrade.none.rawValue) }

    /// "face motion blur 60%, moody blue grade, grain 30%"
    public var summary: String {
        var parts: [String] = []
        if let b = faceMotionBlur, b > 0 { parts.append("face motion blur \(Int((b * 100).rounded()))%") }
        if let g = grade, let gg = TemplateGrade(rawValue: g), gg != .none { parts.append("\(gg.label.lowercased()) grade") }
        if let g = grain, g > 0 { parts.append("grain \(Int((g * 100).rounded()))%") }
        return parts.joined(separator: ", ")
    }
}

/// The hidden prompt layers (owner only). All strings, each ≤ 600 characters. Never identity, outfit, never-add or seed:
/// those always come from the model being shot, so a template works on any model. Empty strings are left out of the JSON.
public struct TemplateLayers: Codable, Hashable, Sendable {
    public var style: String
    public var scene: String
    /// Shot, lens, angle, framing.
    public var camera: String
    /// Light and grade words.
    public var light: String
    /// Added to the model's never-add list.
    public var negative: String
    /// How a product photo is used (Product moment). Empty = the template takes no product photo.
    public var product: String
    public var afterEffects: TemplateAfterEffects?

    public static let maxLength = 600

    public init(style: String = "", scene: String = "", camera: String = "", light: String = "", negative: String = "", product: String = "",
                afterEffects: TemplateAfterEffects? = nil) {
        self.style = style
        self.scene = scene
        self.camera = camera
        self.light = light
        self.negative = negative
        self.product = product
        self.afterEffects = afterEffects
    }

    enum CodingKeys: String, CodingKey { case style, scene, camera, light, negative, product, afterEffects }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        style = c.v(.style, "")
        scene = c.v(.scene, "")
        camera = c.v(.camera, "")
        light = c.v(.light, "")
        negative = c.v(.negative, "")
        product = c.v(.product, "")
        afterEffects = c.o(.afterEffects)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        for (k, v) in [(CodingKeys.style, style), (.scene, scene), (.camera, camera), (.light, light), (.negative, negative), (.product, product)] {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { try c.encode(String(t.prefix(Self.maxLength)), forKey: k) }
        }
        if let fx = afterEffects, !fx.isEmpty { try c.encode(fx, forKey: .afterEffects) }
    }

    public var isEmpty: Bool {
        [style, scene, camera, light, negative, product].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } && (afterEffects?.isEmpty ?? true)
    }

    /// The layers behind a photo made in the Photoshoot inspector, read back from its prompt ("Scene: …", "Camera: …",
    /// "Light: …", "Style: …", "Never add: …"). Never-add items that belong to the model or the global defaults are left out,
    /// as are identity, outfit, direction and seed. (The server's `POST /v1/templates/draft` does this for real; the fake uses it.)
    public static func from(prompt: String, neverAdd: [String] = []) -> TemplateLayers {
        var l = TemplateLayers()
        let own = Set((neverAdd + PromptEngine.globalNever).map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        for raw in prompt.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            func body(_ p: String) -> String? {
                guard line.hasPrefix(p) else { return nil }
                var s = String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                if s.hasSuffix(".") { s.removeLast() }
                return s
            }
            if let s = body("Scene:") { l.scene = s }
            else if let s = body("Camera:") { l.camera = s }
            else if let s = body("Light:") { l.light = s }
            else if let s = body("Style:") { l.style = s == PromptEngine.houseStyle ? "" : s }
            else if let s = body("Never add:") {
                l.negative = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !own.contains($0.lowercased()) }
                    .joined(separator: ", ")
            }
        }
        return l
    }
}

/// One slot of the variation pool. Each still draws one option at random from every slot that has options.
public enum VariationSlot: String, CaseIterable, Codable, Sendable, Identifiable {
    case pose, bodyAngle, framing, expression, background, hands, timeOfDay
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pose: return "Pose"
        case .bodyAngle: return "Body angle"
        case .framing: return "Framing / crop"
        case .expression: return "Expression"
        case .background: return "Background detail"
        case .hands: return "Hand placement"
        case .timeOfDay: return "Time-of-day nuance"
        }
    }

    /// A written Direction replaces these draws; the rest of the template still applies.
    public var replacedByDirection: Bool { self == .pose || self == .bodyAngle }
}

/// `{ [slot]?: string[] }`: ≤ 12 options per slot, each ≤ 200 characters. Empty slots are left out of the JSON.
public struct VariationPool: Codable, Hashable, Sendable {
    public var options: [VariationSlot: [String]]

    public static let maxOptions = 12
    public static let maxLength = 200

    public init(_ options: [VariationSlot: [String]] = [:]) { self.options = options }

    public init(pose: [String] = [], bodyAngle: [String] = [], framing: [String] = [], expression: [String] = [], background: [String] = [],
                hands: [String] = [], timeOfDay: [String] = []) {
        options = [.pose: pose, .bodyAngle: bodyAngle, .framing: framing, .expression: expression, .background: background, .hands: hands, .timeOfDay: timeOfDay]
            .filter { !$0.value.isEmpty }
    }

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Key.self)
        var o: [VariationSlot: [String]] = [:]
        for s in VariationSlot.allCases {
            let v = c.list(Key(stringValue: s.rawValue))
            if !v.isEmpty { o[s] = v }
        }
        options = o
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: Key.self)
        for s in VariationSlot.allCases {
            let v = Self.clean(self[s])
            if !v.isEmpty { try c.encode(v, forKey: Key(stringValue: s.rawValue)) }
        }
    }

    static func clean(_ v: [String]) -> [String] {
        Array(v.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength)) }.filter { !$0.isEmpty }.prefix(maxOptions))
    }

    public subscript(slot: VariationSlot) -> [String] {
        get { options[slot] ?? [] }
        set { options[slot] = newValue.isEmpty ? nil : newValue }
    }

    public var optionCount: Int { VariationSlot.allCases.reduce(0) { $0 + self[$1].count } }
    public var isEmpty: Bool { optionCount == 0 }
}

/// What one shot drew: `{ [slot]?: string, direction?: string }`. A direction replaces pose and bodyAngle.
public struct VariationDraw: Codable, Hashable, Sendable {
    public var picks: [VariationSlot: String]
    public var direction: String?

    public init(picks: [VariationSlot: String] = [:], direction: String? = nil) {
        self.picks = picks
        self.direction = direction
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: VariationPool.Key.self)
        var p: [VariationSlot: String] = [:]
        for s in VariationSlot.allCases {
            if let v = (try? c.decodeIfPresent(String.self, forKey: .init(stringValue: s.rawValue))) ?? nil { p[s] = v }
        }
        picks = p
        direction = (try? c.decodeIfPresent(String.self, forKey: .init(stringValue: "direction"))) ?? nil
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: VariationPool.Key.self)
        for s in VariationSlot.allCases { if let v = picks[s] { try c.encode(v, forKey: .init(stringValue: s.rawValue)) } }
        if let direction { try c.encode(direction, forKey: .init(stringValue: "direction")) }
    }

    public subscript(slot: VariationSlot) -> String? { picks[slot] }

    /// "three-quarter turn · soft smile · …" in slot order.
    public var summary: String {
        (VariationSlot.allCases.compactMap { picks[$0] } + [direction].compactMap { $0 }).joined(separator: " · ")
    }
}

/// private | public
public enum TemplateVisibility: String, CaseIterable, Codable, Sendable {
    case `private`, `public`
    public var label: String { self == .private ? "Private" : "Public" }
}

/// A recent result on the template detail: `{ id, thumb, createdAt }` (newest 6 shots).
public struct TemplateRecent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var thumb: ImageRef
    public var createdAt: Int64

    public init(id: String, thumb: ImageRef, createdAt: Int64 = 0) {
        self.id = id
        self.thumb = thumb
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, thumb, createdAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        thumb = c.v(.thumb, ImageRef())
        createdAt = c.v(.createdAt, 0)
    }
}

/// `Template`. `layers` and `variationPool` arrive only when `isOwner`; `recent` only from GET /v1/templates/{id}.
public struct MuseTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var tags: [String]
    /// "private" | "public"
    public var visibility: String
    public var ownerId: String
    public var ownerName: String
    public var isOwner: Bool
    /// Shoots made with it.
    public var uses: Int
    /// Mine.
    public var favourite: Bool
    public var cover: ImageRef?
    public var acceptsProduct: Bool
    /// The starter-pack slug ("mirror-selfie").
    public var starter: String?
    public var createdFromShotId: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var layers: TemplateLayers?
    public var variationPool: VariationPool?
    public var recent: [TemplateRecent]?

    public init(id: String, name: String, tags: [String] = [], visibility: String = "private", ownerId: String = "", ownerName: String = "", isOwner: Bool = false,
                uses: Int = 0, favourite: Bool = false, cover: ImageRef? = nil, acceptsProduct: Bool = false, starter: String? = nil,
                createdFromShotId: String? = nil, createdAt: Int64 = 0, updatedAt: Int64 = 0, layers: TemplateLayers? = nil,
                variationPool: VariationPool? = nil, recent: [TemplateRecent]? = nil) {
        self.id = id
        self.name = name
        self.tags = tags
        self.visibility = visibility
        self.ownerId = ownerId
        self.ownerName = ownerName
        self.isOwner = isOwner
        self.uses = uses
        self.favourite = favourite
        self.cover = cover
        self.acceptsProduct = acceptsProduct
        self.starter = starter
        self.createdFromShotId = createdFromShotId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.layers = layers
        self.variationPool = variationPool
        self.recent = recent
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tags, visibility, ownerId, ownerName, isOwner, uses, favourite, cover, acceptsProduct, starter, createdFromShotId, createdAt, updatedAt,
             layers, variationPool, recent
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.v(.name, "")
        tags = c.list(.tags)
        visibility = c.v(.visibility, "private")
        ownerId = c.v(.ownerId, "")
        ownerName = c.v(.ownerName, "")
        isOwner = c.v(.isOwner, false)
        uses = c.v(.uses, 0)
        favourite = c.v(.favourite, false)
        cover = c.o(.cover)
        acceptsProduct = c.v(.acceptsProduct, false)
        starter = c.o(.starter)
        createdFromShotId = c.o(.createdFromShotId)
        createdAt = c.v(.createdAt, 0)
        updatedAt = c.v(.updatedAt, 0)
        // Defence in depth: hidden layers are only ever kept for the owner, whatever a server sends.
        layers = isOwner ? c.o(.layers) : nil
        variationPool = isOwner ? c.o(.variationPool) : nil
        recent = c.o(.recent)
    }

    public var isPublic: Bool { visibility == TemplateVisibility.public.rawValue }
    /// "14 uses" / "1 use"
    public var usesLabel: String { uses == 1 ? "1 use" : "\(uses) uses" }

    /// What a non-owner may hold: no layers, no variation pool.
    public var redacted: MuseTemplate {
        var t = self
        t.isOwner = false
        t.layers = nil
        t.variationPool = nil
        return t
    }
}

/// `TemplateDraft`: what "Save as template" would save (POST /v1/templates/draft {fromShotId}). Nothing is stored.
public struct TemplateDraft: Codable, Hashable, Sendable {
    public var name: String
    public var tags: [String]
    public var layers: TemplateLayers
    public var variationPool: VariationPool
    public var cover: ImageRef?
    public var fromShotId: String?

    public init(name: String, tags: [String] = [], layers: TemplateLayers = TemplateLayers(), variationPool: VariationPool = VariationPool(),
                cover: ImageRef? = nil, fromShotId: String? = nil) {
        self.name = name
        self.tags = tags
        self.layers = layers
        self.variationPool = variationPool
        self.cover = cover
        self.fromShotId = fromShotId
    }

    enum CodingKeys: String, CodingKey { case name, tags, layers, variationPool, cover, fromShotId }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = c.v(.name, "")
        tags = c.list(.tags)
        layers = c.v(.layers, TemplateLayers())
        variationPool = c.v(.variationPool, VariationPool())
        cover = c.o(.cover)
        fromShotId = c.o(.fromShotId)
    }
}

public struct TemplateDraftRequest: Codable, Hashable, Sendable {
    public var fromShotId: String
    public init(fromShotId: String) { self.fromShotId = fromShotId }
}

/// GET /v1/templates?scope=all|mine|public|favourites&q=&tag=
public enum TemplateScope: String, CaseIterable, Codable, Sendable {
    case all, mine, `public`, favourites
    public var label: String {
        switch self {
        case .all: return "All"
        case .mine: return "Mine"
        case .public: return "Public"
        case .favourites: return "Favourites"
        }
    }
}

public struct TemplateQuery: Hashable, Sendable {
    public var scope: TemplateScope
    public var q: String
    public var tag: String?

    public init(scope: TemplateScope = .all, q: String = "", tag: String? = nil) {
        self.scope = scope
        self.q = q
        self.tag = tag
    }

    /// The query string for GET /v1/templates. Empty `q` and a nil tag are left out.
    public var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "scope", value: scope.rawValue)]
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { items.append(URLQueryItem(name: "q", value: s)) }
        if let tag, !tag.isEmpty { items.append(URLQueryItem(name: "tag", value: tag)) }
        return items
    }

    /// The server's filter: `all` = mine + public; `mine` = I own; `public` = public (mine included); `favourites` = my favourites I can
    /// still see. `q` matches the name or a tag (case-insensitive substring); `tag` is one exact tag (case-insensitive).
    public func matches(_ t: MuseTemplate) -> Bool {
        guard t.isPublic || t.isOwner else { return false }
        switch scope {
        case .all: break
        case .mine: if !t.isOwner { return false }
        case .public: if !t.isPublic { return false }
        case .favourites: if !t.favourite { return false }
        }
        if let tag, !tag.isEmpty, !t.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return false }
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !s.isEmpty && !t.name.lowercased().contains(s) && !t.tags.contains(where: { $0.lowercased().contains(s) }) { return false }
        return true
    }

    /// Filtered, newest first.
    public func apply(_ all: [MuseTemplate]) -> [MuseTemplate] { all.filter(matches).sorted { $0.createdAt > $1.createdAt } }
}

/// POST /v1/templates. From scratch: `{name, tags?, visibility?, layers?, variationPool?, coverTakeId?}` (an empty pool is
/// auto-suggested). From a shot: `{fromShotId, name, tags?, visibility?, variationPool?}`: the server copies the shot's exact
/// layers and still; the pool sent replaces the suggestion. To save edited layers from a shot, send `layers` with `coverTakeId`
/// instead of `fromShotId` (see `TemplateEditor.createRequest`).
public struct CreateTemplateRequest: Codable, Hashable, Sendable {
    public var name: String
    public var tags: [String]
    public var visibility: String
    public var layers: TemplateLayers?
    public var variationPool: VariationPool?
    public var coverTakeId: String?
    public var fromShotId: String?

    public init(name: String, tags: [String] = [], visibility: String = TemplateVisibility.private.rawValue, layers: TemplateLayers? = nil,
                variationPool: VariationPool? = nil, coverTakeId: String? = nil, fromShotId: String? = nil) {
        self.name = name
        self.tags = tags
        self.visibility = visibility
        self.layers = layers
        self.variationPool = variationPool
        self.coverTakeId = coverTakeId
        self.fromShotId = fromShotId
    }
}

/// PATCH /v1/templates/{id} (owner only). Only the fields sent change; nil fields are left out of the JSON.
public struct TemplatePatch: Codable, Hashable, Sendable {
    public var name: String?
    public var tags: [String]?
    public var visibility: String?
    public var layers: TemplateLayers?
    public var variationPool: VariationPool?

    public init(name: String? = nil, tags: [String]? = nil, visibility: String? = nil, layers: TemplateLayers? = nil, variationPool: VariationPool? = nil) {
        self.name = name
        self.tags = tags
        self.visibility = visibility
        self.layers = layers
        self.variationPool = variationPool
    }
}

/// POST /v1/templates/{id}/prompt `{modelId, outfitId?, direction?, shuffleSeed?, lockSeed?}`: the prompt view. Free.
public struct TemplatePromptRequest: Codable, Hashable, Sendable {
    public var modelId: String
    public var outfitId: String?
    public var direction: String?
    public var shuffleSeed: Int64?
    public var lockSeed: Bool?

    public init(modelId: String, outfitId: String? = nil, direction: String? = nil, shuffleSeed: Int64? = nil, lockSeed: Bool? = nil) {
        self.modelId = modelId
        self.outfitId = outfitId
        let d = direction?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.direction = (d?.isEmpty ?? true) ? nil : d
        self.shuffleSeed = shuffleSeed
        self.lockSeed = lockSeed
    }
}

/// `PromptSlotView`: one line of a template prompt. `locked` marks the one "Template: <name>" line non-owners see.
public struct PromptSlotView: Codable, Hashable, Sendable, Identifiable {
    public var layer: String
    public var text: String
    public var locked: Bool
    public var id: String { layer }

    public init(layer: String, text: String, locked: Bool = false) {
        self.layer = layer
        self.text = text
        self.locked = locked
    }

    enum CodingKeys: String, CodingKey { case layer, text, locked }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        layer = c.v(.layer, "")
        text = c.v(.text, "")
        locked = c.v(.locked, false)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(layer, forKey: .layer)
        try c.encode(text, forKey: .text)
        if locked { try c.encode(true, forKey: .locked) }
    }

    /// The text without its "Label: " prefix.
    public var body: String { PromptSlot(layer, text).body }
}

/// `TemplatePrompt`: `{slots, text, seed (null = a new random seed at shoot time), shuffleSeed, variation? (owner only)}`.
public struct TemplatePrompt: Codable, Hashable, Sendable {
    public var slots: [PromptSlotView]
    public var text: String
    public var seed: Int64?
    public var shuffleSeed: Int64
    public var variation: VariationDraw?

    public init(slots: [PromptSlotView], text: String? = nil, seed: Int64? = nil, shuffleSeed: Int64 = 0, variation: VariationDraw? = nil) {
        self.slots = slots
        self.text = text ?? slots.map(\.text).joined(separator: "\n")
        self.seed = seed
        self.shuffleSeed = shuffleSeed
        self.variation = variation
    }

    enum CodingKeys: String, CodingKey { case slots, text, seed, shuffleSeed, variation }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slots = c.v(.slots, [])
        text = c.v(.text, slots.map(\.text).joined(separator: "\n"))
        seed = c.o(.seed)
        shuffleSeed = c.v(.shuffleSeed, 0)
        variation = c.o(.variation)
    }

    /// True when the prompt shows the template as the single locked line (anyone but its owner).
    public var isLocked: Bool { slots.contains { $0.locked } }
}

extension KeyedDecodingContainer {
    /// A string list that may also arrive as one comma-separated string.
    func list(_ key: Key) -> [String] {
        if let a = (try? decodeIfPresent([String].self, forKey: key)) ?? nil { return a }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
}

/// mulberry32, the same small generator the server uses, so a `shuffleSeed` gives the same draws everywhere.
public struct Mulberry32: Sendable {
    private var a: UInt32
    public init(seed: UInt32) { a = seed }
    public mutating func next() -> Double {
        a = a &+ 0x6D2B_79F5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

/// Template prompt building, the variation draws and the auto-suggested pool: a port of `server/api/src/templates/prompt.ts`
/// so demo mode behaves like the server. The apps never build a template's prompt for a real server; they send the template id
/// plus the user's choices.
public enum TemplateEngine {
    /// Shuffle: a new random shuffleSeed (0 – 2^31−1).
    public static func newShuffleSeed() -> Int64 { Int64.random(in: 0..<(1 << 31)) }

    /// One option per non-empty slot from `shuffleSeed` + the still's index. A direction replaces the pose and body-angle draws.
    public static func draw(_ pool: VariationPool, shuffleSeed: Int64, index: Int = 0, direction: String? = nil) -> VariationDraw {
        let s = UInt32(truncatingIfNeeded: shuffleSeed) ^ (UInt32(truncatingIfNeeded: index + 1) &* 0x9E37_79B1)
        var r = Mulberry32(seed: s)
        let dir = direction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var out = VariationDraw()
        for slot in VariationSlot.allCases {
            let opts = pool[slot].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let pick = opts.isEmpty ? nil : opts[Int(r.next() * Double(opts.count))] // always advance the generator the same way
            if !dir.isEmpty && slot.replacedByDirection { continue }
            if let pick { out.picks[slot] = pick }
        }
        if !dir.isEmpty { out.direction = dir }
        return out
    }

    static func dot(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return "" }
        return ".!?".contains(last) ? t : t + "."
    }

    static func join(_ parts: String?...) -> String {
        parts.compactMap { p -> String? in
            var t = (p ?? "").trimmingCharacters(in: .whitespaces)
            while let l = t.last, ".;,".contains(l) { t.removeLast() }
            return t.isEmpty ? nil : t
        }.joined(separator: "; ")
    }

    /// Stable seed for "Lock look" on a template + model.
    public static func lockedSeed(_ key: String) -> Int64 {
        var h: UInt32 = 2_166_136_261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Int64(h % 1_000_000)
    }

    public struct Build: Sendable {
        public var full: [PromptSlotView]
        public var visible: [PromptSlotView]
        public var seed: Int64?
        public var variation: VariationDraw
        public var fullText: String { full.map(\.text).joined(separator: "\n") }
        public var visibleText: String { visible.map(\.text).joined(separator: "\n") }
    }

    /// Both views of a template prompt: `full` (what the image engine gets, and what the owner may see) and `visible` (everyone
    /// else: the locked "Template: <name>" line in place of the hidden layers).
    public static func build(templateId: String, templateName: String, layers L: TemplateLayers, pool: VariationPool, identity id: PromptIdentity,
                             outfitName: String?, direction: String?, shuffleSeed: Int64, index: Int = 0, lockSeed: Bool, seed: Int64? = nil,
                             hasProduct: Bool = false, houseStyle: String = PromptEngine.houseStyle) -> Build {
        let dir = direction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let v = draw(pool, shuffleSeed: shuffleSeed, index: index, direction: dir)
        let usedSeed: Int64? = lockSeed ? lockedSeed("\(templateId):\(id.name)") : seed
        let identity = PromptSlotView(layer: "identity", text: PromptEngine.identityLine(id))
        let outfit = outfitName.map { PromptSlotView(layer: "outfit", text: "Wearing: \($0.lowercased()) (outfit reference set).") }
        let never = PromptEngine.neverList(id)
        let neg = L.negative.trimmingCharacters(in: .whitespaces)
        let negFull = PromptSlotView(layer: "negative", text: "Never add: \((never + (neg.isEmpty ? [] : [neg.hasSuffix(".") ? String(neg.dropLast()) : neg])).joined(separator: ", ")).")
        let negVisible = PromptSlotView(layer: "negative", text: "Never add: \(never.joined(separator: ", ")).")
        let seedText = lockSeed ? "Seed: \(usedSeed ?? 0) (locked look)." : usedSeed.map { "Seed: \($0) (new each shot)." } ?? "Seed: new each shot."
        let seedSlot = PromptSlotView(layer: "seed", text: seedText)
        let directionSlot = dir.isEmpty ? nil : PromptSlotView(layer: "direction", text: "Direction: \(dot(dir))")
        let p = v.picks
        func line(_ layer: String, _ cond: Bool, _ text: @autoclosure () -> String) -> PromptSlotView? { cond ? PromptSlotView(layer: layer, text: text()) : nil }
        let product = L.product.trimmingCharacters(in: .whitespaces)
        let head: [PromptSlotView?] = [
            line("scene", !L.scene.isEmpty || p[.background] != nil || p[.timeOfDay] != nil, "Scene: \(join(L.scene, p[.background], p[.timeOfDay]))."),
            line("camera", !L.camera.isEmpty || p[.framing] != nil, "Camera: \(join(L.camera, p[.framing]))."),
            line("light", !L.light.isEmpty, "Light: \(join(L.light))."),
            line("pose", [p[.pose], p[.bodyAngle], p[.expression], p[.hands]].contains { $0 != nil }, "Pose: \(join(p[.pose], p[.bodyAngle], p[.expression], p[.hands]))."),
        ]
        let tail: [PromptSlotView?] = [
            line("product", !product.isEmpty, hasProduct ? "Product: \(join(product))." : "Product: \(join(product)) (no product photo: a plausible unbranded product)."),
            PromptSlotView(layer: "style", text: "Style: \(join(L.style, houseStyle))."),
        ]
        let full = ([identity, outfit] + head + [directionSlot] + tail + [negFull, seedSlot]).compactMap { $0 }
        let visible = [identity, outfit, PromptSlotView(layer: "template", text: "Template: \(templateName)", locked: true), directionSlot, negVisible, seedSlot].compactMap { $0 }
        return Build(full: full, visible: visible, seed: usedSeed, variation: v)
    }

    /// The prompt view the app shows when it has no server answer yet: always the locked line, so hidden layers are never
    /// displayed by accident. The owner's full view comes from `POST /v1/templates/{id}/prompt`.
    public static func lockedView(templateName: String, identity: PromptIdentity, outfitName: String?, direction: String?, lockSeed: Bool) -> [PromptSlotView] {
        build(templateId: "", templateName: templateName, layers: TemplateLayers(), pool: VariationPool(), identity: identity, outfitName: outfitName,
              direction: direction, shuffleSeed: 0, lockSeed: false).visible.map { s in
            s.layer == "seed" ? PromptSlotView(layer: "seed", text: lockSeed ? "Seed: locked (same look for this template and model)." : "Seed: new each shot.") : s
        }
    }

    // MARK: Suggested pools (the server's rules)

    private struct Rule {
        let match: [String]
        let pool: VariationPool
    }

    private static let rules: [Rule] = [
        Rule(match: ["mirror", "selfie"], pool: VariationPool(
            pose: ["phone held up covering the face", "phone held low at the chest, face visible over it", "one hip popped, phone at eye level", "leaning a shoulder on the door frame"],
            bodyAngle: ["three-quarter turn to the mirror", "square to the mirror", "side-on, looking at the screen"],
            framing: ["full length in the mirror", "mirror cropped at the knees", "tight on the torso and phone"],
            background: ["unmade bed in the corner", "clothes on a chair", "a bathroom shelf with bottles"],
            hands: ["free hand tugging the hem", "free hand in her hair", "free hand resting on the sink"])),
        Rule(match: ["motion", "blur", "drag"], pool: VariationPool(
            pose: ["turning her head quickly", "mid-laugh, head tipping back", "spinning round towards the camera"],
            bodyAngle: ["three-quarter to camera", "side-on, head turning back"],
            framing: ["waist up", "head and shoulders", "three-quarter length"])),
        Rule(match: ["sun", "close-up", "closeup", "harsh", "shadow"], pool: VariationPool(
            pose: ["chin lifted to the sun", "eyes half closed against the light", "looking just past the lens"],
            framing: ["extreme close-up, cropped at the forehead", "lips and jaw only", "one eye and cheek, very tight"],
            expression: ["squinting slightly", "soft, lips parted", "small closed-mouth smile"])),
        Rule(match: ["lowlight", "low-light", "low light", "moody", "night", "dark"], pool: VariationPool(
            pose: ["sitting on the edge of the bed", "leaning on a window frame", "curled on a sofa"],
            expression: ["distant, unsmiling", "tired half smile", "eyes down"],
            background: ["a lamp glowing out of focus", "city lights through the window", "a TV glow off frame"])),
        Rule(match: ["reflect", "glass", "water", "puddle"], pool: VariationPool(
            pose: ["leaning over the surface", "crouched beside it", "standing with her reflection below her"],
            framing: ["subject top, reflection bottom", "reflection only, subject cropped out at the top", "off-centre, reflection on the right"],
            background: ["a wet street", "a glossy car roof", "a shop window"])),
        Rule(match: ["product", "bottle", "hold"], pool: VariationPool(
            pose: ["product held up next to the cheek", "product in hand at the hip", "applying it"],
            framing: ["product sharp in the foreground, her face soft behind", "hand and product only, her body cropped", "product on a surface, her hand entering"],
            hands: ["fingertips around the cap", "product resting on the palm", "both hands holding it"])),
        Rule(match: ["pov", "candid", "hands entering"], pool: VariationPool(
            pose: ["reaching for the camera", "walking ahead, glancing back", "sitting across a café table"],
            framing: ["off-centre left, lots of space", "tilted horizon", "cut at the chin"],
            hands: ["the photographer’s hand entering frame", "her hand covering part of the lens", "holding a drink towards the lens"])),
    ]

    private static let generic = VariationPool(
        pose: ["weight on one leg, relaxed", "mid-step", "sitting, legs crossed", "leaning on a wall"],
        bodyAngle: ["three-quarter to camera", "facing camera", "side profile"],
        framing: ["full body", "three-quarter length", "waist up"],
        expression: ["easy smile", "neutral, looking away", "laughing"])

    /// The auto-suggested variation pool from a template's style words (a mirror selfie suggests phone-covers-face, phone-low,
    /// three-quarter turn). The first matching rule fills a slot; pose, body angle, framing and expression fall back to generic options.
    public static func suggestPool(layers: TemplateLayers, name: String = "") -> VariationPool {
        let text = [name, layers.style, layers.scene, layers.camera, layers.light, layers.product].joined(separator: " ").lowercased()
        var out = VariationPool()
        for r in rules where r.match.contains(where: { text.contains($0) }) {
            for s in VariationSlot.allCases where out[s].isEmpty { out[s] = r.pool[s] }
        }
        for s in [VariationSlot.pose, .bodyAngle, .framing, .expression] where out[s].isEmpty { out[s] = generic[s] }
        return out
    }

    /// Tags typed as "faceless, golden hour" → ["faceless", "golden hour"], without blanks or duplicates.
    public static func tags(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The tags across a list of templates, most used first (the library's tag chips).
    public static func allTags(_ list: [MuseTemplate]) -> [String] {
        var count: [String: Int] = [:]
        var label: [String: String] = [:]
        for t in list {
            for tag in t.tags {
                count[tag.lowercased(), default: 0] += 1
                if label[tag.lowercased()] == nil { label[tag.lowercased()] = tag }
            }
        }
        return count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.compactMap { label[$0.key] }
    }
}

/// The seven starter templates: public, studio-wide, our own recreations. In demo mode they belong to you (the studio owner),
/// as on the server. Covers are placeholder sample keys; no photos of real people are bundled.
public enum StarterTemplates {
    public static func all(ownerId: String, ownerName: String, now: Int64 = 0) -> [MuseTemplate] {
        func t(_ slug: String, _ name: String, _ cover: String, _ tags: [String], uses: Int, age: Int64, _ l: TemplateLayers) -> MuseTemplate {
            MuseTemplate(id: "tpl_" + slug.replacingOccurrences(of: "-", with: "_"), name: name, tags: tags, visibility: "public", ownerId: ownerId,
                         ownerName: ownerName, isOwner: true, uses: uses, cover: .asset(cover), acceptsProduct: !l.product.isEmpty, starter: slug,
                         createdAt: now - age, updatedAt: now - age, layers: l, variationPool: TemplateEngine.suggestPool(layers: l, name: name))
        }
        let day: Int64 = 86_400_000
        return [
            t("motion-blur-face", "Motion-blur face", "hero", ["Faceless", "Motion"], uses: 128, age: 7 * day, TemplateLayers(
                style: "candid phone photo, everything sharp except the face",
                scene: "busy street corner, shop fronts and passers-by in crisp focus",
                camera: "medium shot, 26mm phone lens, eye level, subject centred",
                light: "flat daylight, neutral colour",
                negative: "blurred background, double exposure",
                afterEffects: TemplateAfterEffects(faceMotionBlur: 0.7, blurAngle: 0, grade: "phone-natural", grain: 0.15))),
            t("mirror-selfie", "Mirror selfie", "c_front", ["Faceless", "Indoor"], uses: 214, age: 6 * day, TemplateLayers(
                style: "real mirror selfie, phone visible in hand, nothing staged",
                scene: "lived-in bedroom with a full-length mirror, a candid room",
                camera: "full shot in the mirror, phone at chest height, slight downward angle",
                light: "window light from the side, slightly underexposed, cool shadows",
                negative: "ring light reflection, two phones",
                afterEffects: TemplateAfterEffects(grade: "underexposed", grain: 0.1))),
            t("harsh-sun-close-up", "Harsh-sun close-up", "face", ["Close-up", "Summer"], uses: 96, age: 5 * day, TemplateLayers(
                style: "extreme close-up, visible pores and skin texture, no retouching",
                scene: "outdoors at midday, sky or a plain wall behind",
                camera: "extreme close-up, 50mm, slightly below eye level, cropped through the face",
                light: "hard midday sun, crisp shadow edges across the face",
                negative: "soft focus, smoothed skin",
                afterEffects: TemplateAfterEffects(grade: "harsh-sun", grain: 0.1))),
            t("moody-low-light", "Moody low-light", "c_face", ["Night", "Moody"], uses: 77, age: 4 * day, TemplateLayers(
                style: "underexposed phone photo, shadows allowed to go deep",
                scene: "dim room or street at night, one practical light source",
                camera: "medium close-up, 35mm, eye level, subject off-centre",
                light: "low light from a single lamp, blue and purple tones",
                negative: "flash, bright fill light",
                afterEffects: TemplateAfterEffects(grade: "moody-blue", grain: 0.3))),
            t("reflection", "Reflection", "profile", ["Reflection", "Outdoor"], uses: 58, age: 3 * day, TemplateLayers(
                style: "the subject plus her reflection as a second image in the frame",
                scene: "a glossy surface beside her: a car roof, shop glass or still water",
                camera: "medium shot, 35mm, low angle so the reflection fills part of the frame",
                light: "soft overcast light, clean and slightly cool",
                negative: "warped face in the reflection",
                afterEffects: TemplateAfterEffects(grade: "faded"))),
            t("product-moment", "Product moment", "g_tq", ["Product", "Ad"], uses: 141, age: 2 * day, TemplateLayers(
                style: "social-ad realism, the product is the hero",
                scene: "a clean tabletop or bathroom shelf with a few everyday props",
                camera: "close shot, 50mm, product in sharp focus, person soft and partly in frame",
                light: "bright window light, fresh and true to life",
                negative: "misspelled label, extra products",
                product: "the product from the product photo, label facing the camera",
                afterEffects: TemplateAfterEffects(grade: "phone-natural"))),
            t("candid-pov", "Candid POV", "g_front", ["Candid", "POV"], uses: 189, age: 1 * day, TemplateLayers(
                style: "phone-camera look from the photographer's point of view, unposed",
                scene: "café table, park path or a car's passenger seat",
                camera: "off-centre framing, 24mm phone lens, hands entering the frame, slight tilt",
                light: "whatever light is there, phone-natural colour",
                negative: "studio backdrop, perfect symmetry",
                afterEffects: TemplateAfterEffects(grade: "phone-natural", grain: 0.05))),
        ]
    }

    /// Demo mode: public templates made by the demo members, so the library shows someone else's work (and the locked prompt line).
    public static func memberTemplates(now: Int64 = 0) -> [MuseTemplate] {
        let hour: Int64 = 3_600_000
        func t(_ id: String, _ name: String, _ cover: String, _ tags: [String], owner: (String, String), uses: Int, age: Int64, visibility: String = "public",
               _ l: TemplateLayers) -> MuseTemplate {
            MuseTemplate(id: id, name: name, tags: tags, visibility: visibility, ownerId: owner.0, ownerName: owner.1, isOwner: false, uses: uses,
                         cover: .asset(cover), createdAt: now - age, updatedAt: now - age, layers: l, variationPool: TemplateEngine.suggestPool(layers: l, name: name))
        }
        return [
            t("tpl_maya_golden", "Golden hour walk", "g_side", ["Golden hour", "Outdoor"], owner: ("u_maya", "maya@studio.com"), uses: 23, age: 5 * hour, TemplateLayers(
                style: "warm candid street photo", scene: "quiet residential street at golden hour, long shadows",
                camera: "full shot, 35mm, from across the street", light: "low warm sun from behind, glowing hair edges",
                afterEffects: TemplateAfterEffects(grade: "golden", grain: 0.1))),
            t("tpl_theo_backstage", "Backstage flash", "g_back", ["Flash", "Night"], owner: ("u_theo", "theo@studio.com"), uses: 9, age: 30 * hour, TemplateLayers(
                style: "direct on-camera flash, party snapshot", scene: "corridor behind a venue, posters on the wall",
                camera: "medium shot, 28mm, straight on", light: "hard direct flash, dark falloff behind",
                afterEffects: TemplateAfterEffects(grade: "faded", grain: 0.2))),
            // Someone else's private template: never visible in the library.
            t("tpl_theo_private", "Theo's test look", "c_tq", ["Test"], owner: ("u_theo", "theo@studio.com"), uses: 2, age: 40 * hour, visibility: "private",
              TemplateLayers(style: "test")),
        ]
    }
}

/// The template editor's state (Save as template, Edit, from scratch), and the request it turns into.
public struct TemplateForm: Equatable, Sendable {
    /// Editing an existing template (PATCH), or nil for a new one (POST).
    public var templateId: String?
    /// "Save as template" on this shot.
    public var fromShotId: String?
    public var name: String
    public var tagsText: String
    public var visibility: TemplateVisibility
    public var layers: TemplateLayers
    public var pool: VariationPool
    public var cover: ImageRef?
    /// The layers the server copied from the shot (the draft); while unchanged the template is saved with `fromShotId`.
    public var draftLayers: TemplateLayers?

    public init(templateId: String? = nil, fromShotId: String? = nil, name: String = "", tags: [String] = [], visibility: TemplateVisibility = .private,
                layers: TemplateLayers = TemplateLayers(), pool: VariationPool = VariationPool(), cover: ImageRef? = nil, draftLayers: TemplateLayers? = nil) {
        self.templateId = templateId
        self.fromShotId = fromShotId
        self.name = name
        self.tagsText = tags.joined(separator: ", ")
        self.visibility = visibility
        self.layers = layers
        self.pool = pool
        self.cover = cover
        self.draftLayers = draftLayers
    }

    /// Save as template: private by default, with the draft's layers and suggested pool.
    public static func from(draft d: TemplateDraft) -> TemplateForm {
        TemplateForm(fromShotId: d.fromShotId, name: d.name, tags: d.tags, layers: d.layers, pool: d.variationPool, cover: d.cover, draftLayers: d.layers)
    }

    /// Edit: an owned template (which carries its layers).
    public static func edit(_ t: MuseTemplate) -> TemplateForm {
        TemplateForm(templateId: t.id, name: t.name, tags: t.tags, visibility: TemplateVisibility(rawValue: t.visibility) ?? .private,
                     layers: t.layers ?? TemplateLayers(), pool: t.variationPool ?? VariationPool(), cover: t.cover)
    }

    public var tags: [String] { TemplateEngine.tags(from: tagsText) }
    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var canSave: Bool { !trimmedName.isEmpty }
    public var isEditing: Bool { templateId != nil }

    /// POST /v1/templates. Unchanged layers from a shot use `fromShotId` (the server copies the exact layers and still);
    /// edited layers are sent as they are, with the shot as `coverTakeId`.
    public var createRequest: CreateTemplateRequest {
        if let sid = fromShotId, layers == draftLayers {
            return CreateTemplateRequest(name: trimmedName, tags: tags, visibility: visibility.rawValue, variationPool: pool, fromShotId: sid)
        }
        return CreateTemplateRequest(name: trimmedName, tags: tags, visibility: visibility.rawValue, layers: layers, variationPool: pool, coverTakeId: fromShotId)
    }

    /// PATCH /v1/templates/{id}.
    public var patch: TemplatePatch {
        TemplatePatch(name: trimmedName, tags: tags, visibility: visibility.rawValue, layers: layers, variationPool: pool)
    }

    /// "Suggest again": the auto-suggested pool for the current layers and name.
    public mutating func suggestPool() { pool = TemplateEngine.suggestPool(layers: layers, name: name) }

    public mutating func addOption(_ text: String, to slot: VariationSlot) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !pool[slot].contains(t), pool[slot].count < VariationPool.maxOptions else { return }
        pool[slot].append(String(t.prefix(VariationPool.maxLength)))
    }

    public mutating func removeOption(at i: Int, from slot: VariationSlot) {
        guard pool[slot].indices.contains(i) else { return }
        pool[slot].remove(at: i)
    }
}
