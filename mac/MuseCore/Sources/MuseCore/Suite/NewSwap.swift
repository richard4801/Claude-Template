import Foundation

// New Swap (beta, plans/new-swap.md): remix a clip with toggles. The person adds a video (upload, link or Library), then
// switches on what should change: Background, Outfit, Character, Look & light. Each toggle has one short field; anything
// off is kept from the clip. The server builds the prompt (script suite.remix) and Auto picks a model and says why.
// Pure: the draft, the request's `remix` object, what is missing, Claude's changes and the server's views.

// MARK: The request's toggles (server suite/plan.ts RemixSchema)

public struct RemixBackground: Codable, Hashable, Sendable {
    public var mode: String
    public var words: String?
    public var image: ImageRef?
    public var name: String?
    public static func describe(_ words: String) -> RemixBackground { RemixBackground(mode: "describe", words: words) }
    public static func photo(_ image: ImageRef, name: String?) -> RemixBackground { RemixBackground(mode: "photo", image: image, name: name) }
}

public struct RemixOutfit: Codable, Hashable, Sendable {
    public var kind: String
    public var outfitId: String?
    public var image: ImageRef?
    public var name: String?
    public var words: String?
}

public struct RemixCharacter: Codable, Hashable, Sendable {
    public var kind: String
    public var modelId: String?
    public var image: ImageRef?
    public var name: String?
}

public struct RemixLook: Codable, Hashable, Sendable {
    public var words: String
}

/// The changes. A toggle left out is kept from the clip.
public struct RemixToggles: Codable, Hashable, Sendable {
    public var background: RemixBackground?
    public var outfit: RemixOutfit?
    public var character: RemixCharacter?
    public var look: RemixLook?
    public init(background: RemixBackground? = nil, outfit: RemixOutfit? = nil, character: RemixCharacter? = nil, look: RemixLook? = nil) {
        self.background = background
        self.outfit = outfit
        self.character = character
        self.look = look
    }
}

// MARK: The panel's draft

public enum RemixBackgroundMode: String, CaseIterable, Hashable, Sendable {
    case describe, photo
    public var label: String { self == .describe ? "Describe" : "New photo" }
}

public enum RemixOutfitKind: String, CaseIterable, Hashable, Sendable {
    case outfit, product, words
    public var label: String {
        switch self {
        case .outfit: return "Her outfit"
        case .product: return "Product photo"
        case .words: return "Words"
        }
    }
}

/// Character: her (default, strict figure lock), or the optional face swap from a photo (face only, off by default).
public enum RemixCharacterKind: String, CaseIterable, Hashable, Sendable {
    case model, face
    public var label: String { self == .model ? "Her" : "Face swap" }
}

/// The part of the clip used (the trimmer), in seconds.
public struct RemixRange: Hashable, Sendable {
    public var from: Double
    public var to: Double
    public init(from: Double, to: Double) {
        self.from = from
        self.to = to
    }
    public var seconds: Double { max(0, to - from) }
}

public struct RemixDraft: Hashable, Sendable {
    public var backgroundOn = false
    public var backgroundMode: RemixBackgroundMode = .describe
    public var backgroundWords = ""
    public var backgroundImage: ImageRef?
    public var backgroundName: String?

    public var outfitOn = false
    public var outfitKind: RemixOutfitKind = .outfit
    public var outfitId: String?
    public var productImage: ImageRef?
    public var productName: String?
    public var outfitWords = ""

    public var characterOn = false
    public var characterKind: RemixCharacterKind = .model
    public var modelId: String?
    public var faceImage: ImageRef?
    public var faceName: String?

    public var lookOn = false
    public var lookWords = ""

    /// The trimmer's part of the clip (nil = the whole clip).
    public var range: RemixRange?
    /// The picked model (nil = Auto).
    public var engineModel: String?
    public var keepAudio = true

    public init() {}

    public var anyOn: Bool { backgroundOn || outfitOn || characterOn || lookOn }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What a turned-on toggle still needs, in plain words (the server says the same), or nil when it can be priced.
    public var missing: String? {
        if !anyOn { return "Turn on a change: Background, Outfit, Character or Look & light" }
        if backgroundOn {
            if backgroundMode == .describe && Self.trimmed(backgroundWords).isEmpty { return "Background · Describe: write the new place" }
            if backgroundMode == .photo && backgroundImage == nil { return "Background · New photo: pick a location or upload a picture" }
        }
        if outfitOn {
            switch outfitKind {
            case .outfit where outfitId == nil: return "Outfit: pick one of her outfits"
            case .product where productImage == nil: return "Outfit · Product photo: upload the picture"
            case .words where Self.trimmed(outfitWords).isEmpty: return "Outfit · Words: write what they wear"
            default: break
            }
        }
        if characterOn {
            if characterKind == .model && modelId == nil { return "Character: pick her" }
            if characterKind == .face && faceImage == nil { return "Face swap: add a photo of the face" }
        }
        if lookOn && Self.trimmed(lookWords).isEmpty { return "Look & light: write the time of day, light or colour grade" }
        return nil
    }

    /// The request's `remix` object: only the toggles that are on, each with only its own field.
    public var toggles: RemixToggles {
        var x = RemixToggles()
        if backgroundOn {
            if backgroundMode == .photo, let img = backgroundImage { x.background = .photo(img, name: backgroundName.map { String($0.prefix(120)) }) }
            else if backgroundMode == .describe { x.background = .describe(String(Self.trimmed(backgroundWords).prefix(400))) }
        }
        if outfitOn {
            switch outfitKind {
            case .outfit: if let id = outfitId { x.outfit = RemixOutfit(kind: "outfit", outfitId: id) }
            case .product: if let img = productImage { x.outfit = RemixOutfit(kind: "product", image: img, name: productName.map { String($0.prefix(120)) }) }
            case .words: x.outfit = RemixOutfit(kind: "words", words: String(Self.trimmed(outfitWords).prefix(400)))
            }
        }
        if characterOn {
            switch characterKind {
            case .model: if let m = modelId { x.character = RemixCharacter(kind: "model", modelId: m) }
            case .face: if let img = faceImage { x.character = RemixCharacter(kind: "face", image: img, name: faceName.map { String($0.prefix(120)) }) }
            }
        }
        if lookOn { x.look = RemixLook(words: String(Self.trimmed(lookWords).prefix(400))) }
        return x
    }

    /// The toggles that are off, for the "Kept from the clip" line.
    public var keptLine: String {
        var k: [String] = ["motion", "camera"]
        if keepAudio { k.append("sound") }
        if !characterOn { k.append("the person") }
        if !outfitOn { k.append("the outfit") }
        if !backgroundOn { k.append("the place") }
        if !lookOn { k.append("the light") }
        return "Kept from the clip: " + k.joined(separator: ", ")
    }
}

extension ShotRequest {
    /// New Swap: the source clip, the toggles, the trimmer's part and the model (nil = Auto).
    public static func remix(clipId: String, draft d: RemixDraft, quality: String = "standard", takes: Int = 1, title: String? = nil) -> ShotRequest {
        var r = ShotRequest(mode: "remix", title: title, prompt: "", quality: quality, takes: takes, clipId: clipId, keepAudio: d.keepAudio, engineModel: d.engineModel)
        r.remix = d.toggles
        if let g = d.range { r.range = [g.from, g.to] }
        return r
    }
}

// MARK: Claude's draft (server suite/assist.ts): New Swap's fields in the shared draft

public enum RemixDraftSync {
    /// The shared draft's New Swap fields from the panel (tool "remix", clipId, remix, range, engineModel).
    public static func fields(_ d: RemixDraft, clipId: String?) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["tool": .string("remix")]
        if let c = clipId { o["clipId"] = .string(c) }
        if let data = try? JSONEncoder().encode(d.toggles), let v = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let m) = v, !m.isEmpty { o["remix"] = v }
        if let g = d.range { o["range"] = .array([.number(g.from), .number(g.to)]) }
        if let m = d.engineModel { o["engineModel"] = .string(m) }
        return o
    }

    /// Claude's New Swap fields laid over the panel: each toggle given replaces it, one left out is switched off; the
    /// range and model follow. Returns the new draft and what changed, in words, for "Claude set …".
    public static func apply(_ raw: [String: JSONValue], to base: RemixDraft) -> (draft: RemixDraft, changed: [String]) {
        var d = base
        var changed: [String] = []
        func str(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s }; return nil }
        func obj(_ v: JSONValue?) -> [String: JSONValue]? { if case .object(let o)? = v { return o }; return nil }
        func image(_ v: JSONValue?) -> ImageRef? {
            guard let o = obj(v) else { return nil }
            let r = ImageRef(asset: str(o["asset"]), url: str(o["url"]))
            return r.asset == nil && r.url == nil ? nil : r
        }
        let x = obj(raw["remix"]) ?? [:]
        // Background
        if let b = obj(x["background"]) {
            d.backgroundOn = true
            if str(b["mode"]) == "photo", let img = image(b["image"]) { d.backgroundMode = .photo; d.backgroundImage = img; d.backgroundName = str(b["name"]) }
            else { d.backgroundMode = .describe; d.backgroundWords = str(b["words"]) ?? "" }
        } else { d.backgroundOn = false }
        // Outfit
        if let o = obj(x["outfit"]) {
            d.outfitOn = true
            switch str(o["kind"]) {
            case "product": d.outfitKind = .product; d.productImage = image(o["image"]); d.productName = str(o["name"])
            case "words": d.outfitKind = .words; d.outfitWords = str(o["words"]) ?? ""
            default: d.outfitKind = .outfit; d.outfitId = str(o["outfitId"])
            }
        } else { d.outfitOn = false }
        // Character
        if let c = obj(x["character"]) {
            d.characterOn = true
            if str(c["kind"]) == "face" { d.characterKind = .face; d.faceImage = image(c["image"]); d.faceName = str(c["name"]) }
            else { d.characterKind = .model; d.modelId = str(c["modelId"]) }
        } else { d.characterOn = false }
        // Look & light
        if let l = obj(x["look"]) { d.lookOn = true; d.lookWords = str(l["words"]) ?? "" } else { d.lookOn = false }
        // The part of the clip and the model
        if case .array(let a)? = raw["range"], a.count == 2, case .number(let f) = a[0], case .number(let t) = a[1], t > f { d.range = RemixRange(from: f, to: t) } else { d.range = nil }
        d.engineModel = str(raw["engineModel"])
        if d.backgroundOn != base.backgroundOn || d.backgroundMode != base.backgroundMode || d.backgroundWords != base.backgroundWords || d.backgroundImage != base.backgroundImage { changed.append("Background") }
        if d.outfitOn != base.outfitOn || d.outfitKind != base.outfitKind || d.outfitId != base.outfitId || d.outfitWords != base.outfitWords || d.productImage != base.productImage { changed.append("Outfit") }
        if d.characterOn != base.characterOn || d.characterKind != base.characterKind || d.modelId != base.modelId || d.faceImage != base.faceImage { changed.append("Character") }
        if d.lookOn != base.lookOn || d.lookWords != base.lookWords { changed.append("Look & light") }
        if d.range != base.range { changed.append("Trim") }
        if d.engineModel != base.engineModel { changed.append("Model") }
        return (d, changed)
    }
}

// MARK: The server's views

/// The estimate's `remix` block: the part used, the trimmer's limits, Auto's reason and the billed seconds.
public struct RemixEstimate: Codable, Hashable, Sendable {
    public struct Uses: Codable, Hashable, Sendable { public var from: Double; public var to: Double; public var of: Double }
    public struct Trim: Codable, Hashable, Sendable { public var needed: Bool; public var tooShort: Bool; public var minSeconds: Double; public var maxSeconds: Double }
    public struct Billed: Codable, Hashable, Sendable { public var output: Double; public var input: Double; public var inRate: Bool }
    public var toggles: [String]
    public var why: String?
    public var tested: Bool
    public var keepAudio: Bool
    public var uses: Uses
    public var trim: Trim
    public var billedSeconds: Billed?
}

/// POST /v1/suite/remix/models: every model that edits a video, for these toggles and this clip.
public struct RemixModels: Codable, Hashable, Sendable {
    public struct Auto: Codable, Hashable, Sendable { public var model: String?; public var why: String? }
    public struct Limits: Codable, Hashable, Sendable {
        public var minSeconds: Double
        public var maxSeconds: Double
        public var resolutions: [String]
        public var maxImages: Int
        public var keepsAudio: Bool
        public var soundNote: String
    }
    public struct Price: Codable, Hashable, Sendable {
        public var resolution: String
        /// nil: priced live by the provider when picked (Wan 3.0).
        public var perSec: Double?
        public var seconds: Double?
        public var trimNeeded: Bool?
        public var usd: Double?
        public var inputBilled: String
    }
    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public var model: String
        public var label: String
        /// "yes", "prompt" (by instruction only) or "adapted" (MUSE sends the clip another way; `notes` say how).
        /// Owner 2026-11-12: every model can be picked; only `unavailable` stops one.
        public var support: String
        public var reason: String?
        public var notes: [String]?
        /// How the clip reaches the model: edit, reference, frames or text.
        public var route: String?
        public var unavailable: String?
        public var tested: Bool
        public var auto: Bool
        public var why: String?
        public var limits: Limits
        public var price: Price
        /// The list's group: "auto", "edit", "reference", "frames" or "text" (older servers: from `route`).
        public var group: String?
        /// Its provider refused a run recently: still pickable, it may refuse again.
        public var warning: String?
        public var id: String { model }
        /// The group this row shows under.
        public var groupId: String { group ?? (auto ? "auto" : route ?? "edit") }
        /// The row's line under the name: why it can't run, else a recent refusal, else what MUSE does, else its limits.
        public var line: String {
            if unavailable != nil { return detail }
            return warning ?? adaptedLine ?? detail
        }
        /// Can be picked: everything that can run (no model is greyed out for what it's made for).
        public var pickable: Bool { unavailable == nil }
        /// The row's second line: limits, sound, "not tested yet", or why it can't run.
        public var detail: String {
            if let u = unavailable { return "Not available: \(u)" }
            var p = ["up to \(Pricing.trimNum(limits.maxSeconds)) s", limits.resolutions.joined(separator: "/"), limits.soundNote]
            if support == "prompt" { p.append("by instruction only") }
            if price.perSec == nil { p.append("priced when you pick it") }
            if !tested { p.append("not tested yet") }
            return p.joined(separator: ", ")
        }
        /// What MUSE does with an adapted model here (its first note), or nil.
        public var adaptedLine: String? { support == "adapted" ? (notes?.first ?? reason) : nil }
    }
    public struct Group: Codable, Hashable, Sendable { public var id: String; public var label: String }
    public var toggles: [String]
    public var auto: Auto?
    public var models: [Row]
    /// The list's groups in order, with their names (older servers: MUSE's own).
    public var groups: [Group]?

    public static let defaultGroups = [Group(id: "auto", label: "Auto picks"), Group(id: "edit", label: "Edits the clip"),
                                       Group(id: "reference", label: "Uses the clip as reference"), Group(id: "frames", label: "From frames"),
                                       Group(id: "text", label: "From words only")]
    /// The rows by group, in the list's order; empty groups left out.
    public var grouped: [(group: Group, rows: [Row])] {
        (groups ?? Self.defaultGroups).compactMap { g in
            let rows = models.filter { $0.groupId == g.id }
            return rows.isEmpty ? nil : (g, rows)
        }
    }

    enum CodingKeys: String, CodingKey { case toggles, auto, models, groups }
    /// A row that doesn't decode is left out alone (owner bug 2026-11-12: one bad row must never hide the whole list).
    private struct LossyRow: Decodable { let row: Row?; init(from d: Decoder) throws { row = try? Row(from: d) } }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        toggles = (try? c.decode([String].self, forKey: .toggles)) ?? []
        auto = try? c.decodeIfPresent(Auto.self, forKey: .auto)
        models = ((try? c.decode([LossyRow].self, forKey: .models)) ?? []).compactMap(\.row)
        groups = try? c.decodeIfPresent([Group].self, forKey: .groups)
    }
    public init(toggles: [String] = [], auto: Auto? = nil, models: [Row] = [], groups: [Group]? = nil) {
        self.toggles = toggles
        self.auto = auto
        self.models = models
        self.groups = groups
    }
}

/// The model pill's request body.
public struct RemixModelsRequest: Codable, Hashable, Sendable {
    public var remix: RemixToggles
    public var clipId: String?
    public var range: [Double]?
    public init(remix: RemixToggles, clipId: String?, range: [Double]?) {
        self.remix = remix
        self.clipId = clipId
        self.range = range
    }
}

// New Swap's two calls. Kept out of the MuseAPI protocol so every client and test double compiles unchanged: the HTTP
// client serves them; others (demo mode) say plainly that they aren't there.
extension MuseAPI {
    /// POST /v1/suite/remix/models
    public func suiteRemixModels(_ req: RemixModelsRequest) async throws -> RemixModels {
        guard let h = self as? HTTPMuseAPI else { throw ApiError("unavailable", "The model list needs the MUSE server") }
        return try await h.suiteCall("POST", "v1/suite/remix/models", body: try JSONEncoder().encode(req))
    }
    /// GET /v1/clips/{id}: one clip of this studio (the video Claude set as New Swap's source).
    public func suiteClip(id: String) async throws -> Clip {
        guard let h = self as? HTTPMuseAPI else { throw ApiError("unavailable", "Loading that clip needs the MUSE server") }
        let c: Clip = try await h.suiteCall("GET", "v1/clips/\(id)")
        return h.absolutize(c)
    }
    /// POST /v1/clips/from-take: a finished take from the Library as a source clip (copied; the take stays as it is).
    public func clipFromTake(_ takeId: String) async throws -> Clip {
        guard let h = self as? HTTPMuseAPI else { throw ApiError("unavailable", "Picking from the Library needs the MUSE server") }
        let c: Clip = try await h.suiteCall("POST", "v1/clips/from-take", body: try JSONEncoder().encode(["takeId": takeId]))
        return h.absolutize(c)
    }
}
