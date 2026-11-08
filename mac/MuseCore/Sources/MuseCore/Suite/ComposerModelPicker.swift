import Foundation

// The owner's model picker in the AI Suite composer (owner request 2026-11-08: "bring back a model selector"). The owner
// picks any registry model the tool can run (GET /v1/suite/settings, owner only), not just the quality's ladder; the
// composer then follows that model's limits (its lengths and aspect ratios) and shows its price. Members never see any
// of it: they keep the quality choice, and the server refuses `engineModel` from them (403 owner_only).

// MARK: Registry details the picker reads (server registry.ts `modelView`)

public struct SuiteModelModes: Codable, Hashable, Sendable {
    public var text: Bool
    public var image: Bool
    public var reference: Bool
    public var guide: Bool
    public var recast: Bool

    public init(text: Bool = false, image: Bool = false, reference: Bool = false, guide: Bool = false, recast: Bool = false) {
        self.text = text
        self.image = image
        self.reference = reference
        self.guide = guide
        self.recast = recast
    }

    enum CodingKeys: String, CodingKey { case text, image, reference, guide, recast }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        text = c.v(.text, false)
        image = c.v(.image, false)
        reference = c.v(.reference, false)
        guide = c.v(.guide, false)
        recast = c.v(.recast, false)
    }
}

public struct SuiteModelFrames: Codable, Hashable, Sendable {
    public var start: Bool
    public var end: Bool
    public var middle: Int
    public var withRefs: Bool

    public init(start: Bool = false, end: Bool = false, middle: Int = 0, withRefs: Bool = false) {
        self.start = start
        self.end = end
        self.middle = middle
        self.withRefs = withRefs
    }

    enum CodingKeys: String, CodingKey { case start, end, middle, withRefs }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = c.v(.start, false)
        end = c.v(.end, false)
        middle = c.v(.middle, 0)
        withRefs = c.v(.withRefs, false)
    }
}

public struct SuiteModelRefs: Codable, Hashable, Sendable {
    public var images: Int
    public var videos: Int
    public var audios: Int

    public init(images: Int = 0, videos: Int = 0, audios: Int = 0) {
        self.images = images
        self.videos = videos
        self.audios = audios
    }

    enum CodingKeys: String, CodingKey { case images, videos, audios }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        images = c.v(.images, 0)
        videos = c.v(.videos, 0)
        audios = c.v(.audios, 0)
    }
}

/// A model's lengths: a range, or only some values (Veo: 4, 6, 8).
public struct SuiteModelDuration: Codable, Hashable, Sendable {
    public var min: Double
    public var max: Double
    public var allowed: [Double]?

    public init(min: Double, max: Double, allowed: [Double]? = nil) {
        self.min = min
        self.max = max
        self.allowed = allowed
    }

    enum CodingKeys: String, CodingKey { case min, max, allowed }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        min = c.v(.min, 1)
        max = c.v(.max, 15)
        allowed = c.o(.allowed)
    }
}

extension SuiteRegistryModel {
    /// The input slots this model takes, as the server works them out for a tier (registry.ts `inputSlotsOf`).
    public var inputs: SuiteInputs {
        SuiteInputs(start: modes.image && frames.start, end: modes.image && frames.end,
                    middle: modes.image ? Swift.min(8, frames.middle) : 0,
                    images: Swift.min(6, refs.images), videos: Swift.min(3, refs.videos), audio: refs.audios > 0,
                    framesWithRefs: modes.image && frames.withRefs)
    }

    /// Its own price per second at this resolution, the owner's price correction applied.
    public func perSec(_ resolution: String?) -> Double? {
        (resolutions.first { $0.id == resolution } ?? resolutions.first).map { $0.perSec * priceScale }
    }
}

// MARK: The owner's catalog entries (GET /v1/suite/catalog `engines[]`, owner only; plans/api.md "Owner's model picker")

/// One model the owner can pick: built-in or the owner's own provider's (`custom`), video or image. Prices are after the
/// model's price correction.
public struct SuiteModelOption: Codable, Hashable, Sendable, Identifiable {
    public struct Price: Codable, Hashable, Sendable {
        /// "per_run" or "per_second".
        public var basis: String
        public var usd: Double
        public init(basis: String, usd: Double) {
            self.basis = basis
            self.usd = usd
        }
    }

    public var model: String
    public var name: String
    public var kind: String
    public var custom: Bool
    /// The first quality whose ladder lists it, and every one that does.
    public var tier: String?
    public var tiers: [String]
    /// The resolution its ladder runs it at (else its best).
    public var resolution: String?
    public var resolutions: [SuiteResolution]
    public var perSec: Double?
    /// Per-run price (an image model's one photo; a per-run custom video model).
    public var perRun: Double?
    public var minSeconds: Double?
    public var maxSeconds: Double?
    public var allowedSeconds: [Double]?
    public var aspectRatios: [String]
    public var inputs: SuiteInputs?
    public var price: Price?
    public var id: String { model }

    public init(model: String, name: String, kind: String = "video", custom: Bool = false, tier: String? = nil, tiers: [String] = [], resolution: String? = nil,
                resolutions: [SuiteResolution] = [], perSec: Double? = nil, perRun: Double? = nil, minSeconds: Double? = nil, maxSeconds: Double? = nil,
                allowedSeconds: [Double]? = nil, aspectRatios: [String] = [], inputs: SuiteInputs? = nil, price: Price? = nil) {
        self.model = model
        self.name = name
        self.kind = kind
        self.custom = custom
        self.tier = tier
        self.tiers = tiers
        self.resolution = resolution
        self.resolutions = resolutions
        self.perSec = perSec
        self.perRun = perRun
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.allowedSeconds = allowedSeconds
        self.aspectRatios = aspectRatios
        self.inputs = inputs
        self.price = price
    }

    enum CodingKeys: String, CodingKey {
        case model, name, kind, custom, tier, tiers, resolution, resolutions, perSec, perRun, minSeconds, maxSeconds, allowedSeconds, aspectRatios, inputs, price
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        name = c.v(.name, model)
        kind = c.v(.kind, "video")
        custom = c.v(.custom, false)
        tier = c.o(.tier)
        tiers = c.v(.tiers, [])
        resolution = c.o(.resolution)
        resolutions = c.v(.resolutions, [])
        perSec = c.o(.perSec)
        perRun = c.o(.perRun)
        minSeconds = c.o(.minSeconds)
        maxSeconds = c.o(.maxSeconds)
        allowedSeconds = c.o(.allowedSeconds)
        aspectRatios = c.v(.aspectRatios, [])
        inputs = c.o(.inputs)
        price = c.o(.price)
    }

    public var isVideo: Bool { kind == "video" }

    /// An older server without `engines[]`: the same entry from the owner's registry (GET /v1/suite/settings), when the
    /// server would list it (switched on, licensed, its provider set up, makes shots).
    public static func from(_ m: SuiteRegistryModel, ladder: [String: [SuiteLadderStep]]) -> SuiteModelOption? {
        guard m.enabled, !m.blocked, m.status != "removed", m.configured, !m.needsAck, m.kind == "video", !m.resolutions.isEmpty,
              m.modes.text || m.modes.image || m.modes.reference else { return nil }
        let tiers = SuiteText.tierIds.filter { (ladder[$0] ?? []).contains { $0.model == m.id } }
        let ladderRes = tiers.lazy.compactMap { t in ladder[t]?.first { $0.model == m.id }?.resolution }.first
        let res = ladderRes.flatMap { r in m.resolutions.contains { $0.id == r } ? r : nil } ?? m.resolutions.last!.id
        let rs = m.resolutions.map { SuiteResolution(id: $0.id, label: $0.label, perSec: ($0.perSec * m.priceScale * 10000).rounded() / 10000) }
        let per = rs.first { $0.id == res }?.perSec
        return SuiteModelOption(model: m.id, name: m.name, kind: "video", custom: m.custom, tier: tiers.first, tiers: tiers, resolution: res, resolutions: rs,
                           perSec: per, minSeconds: m.duration?.min, maxSeconds: m.duration?.max, allowedSeconds: m.duration?.allowed,
                           aspectRatios: m.aspectRatios, inputs: m.inputs, price: per.map { Price(basis: "per_second", usd: $0) })
    }
}

// MARK: The picker

public enum ComposerModelPicker {
    /// Every model the owner can pick: the catalog's `engines[]`, else (an older server) worked out from the registry.
    public static func engines(_ catalog: SuiteCatalog?, _ settings: SuiteSettings?) -> [SuiteModelOption] {
        if let e = catalog?.engines { return e }
        guard let s = settings else { return [] }
        return s.models.compactMap { SuiteModelOption.from($0, ladder: s.ladder) }
    }

    /// Whether the picker shows for this tool. Swap runs on its add-on and Recast and Extend on their own ladders.
    public static func offered(_ tool: ComposerTool) -> Bool {
        switch tool {
        case .shot, .talking, .ugc, .storyboard, .photo: return true
        case .swap, .recast, .extend: return false
        }
    }

    /// Video models for a shot tool (Talking needs an audio slot, UGC ad a reference image); image models for Photo.
    public static func supports(_ e: SuiteModelOption, tool: ComposerTool) -> Bool {
        switch tool {
        case .photo: return e.kind == "image"
        case .shot, .storyboard: return e.isVideo
        case .talking: return e.isVideo && e.inputs?.audio == true
        case .ugc: return e.isVideo && (e.inputs?.images ?? 0) > 0
        case .swap, .recast, .extend: return false
        }
    }

    /// The list: this quality's ladder first (its order), then the others in quality order, then by name; the owner's own
    /// provider models last. A search filters by name or id.
    public static func options(_ catalog: SuiteCatalog?, _ settings: SuiteSettings?, tool: ComposerTool, quality: String, search: String = "") -> [SuiteModelOption] {
        let all = engines(catalog, settings).filter { supports($0, tool: tool) }
        let ladder = (catalog?.tier(quality)?.models ?? []).map(\.model)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let found = q.isEmpty ? all : all.filter { "\($0.name) \($0.model)".lowercased().contains(q) }
        func rank(_ e: SuiteModelOption) -> (Int, Int, Int) {
            let onThis = e.tiers.contains(quality) ? 0 : 1
            let inLadder = ladder.firstIndex(of: e.model) ?? Int.max
            let firstTier = e.tier.flatMap { SuiteText.tierIds.firstIndex(of: $0) } ?? Int.max
            return (e.custom ? 1 : 0, onThis, onThis == 0 ? inLadder : firstTier)
        }
        return found.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The pinned video model.
    public static func pinned(_ d: ComposerDraft, _ catalog: SuiteCatalog?, _ settings: SuiteSettings?) -> SuiteModelOption? {
        guard let id = d.engineModel else { return nil }
        return engines(catalog, settings).first { $0.model == id }
    }

    /// The Length range: the pinned model's, else the quality's.
    public static func lengthRange(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> ClosedRange<Int> {
        guard let e = pinned(d, catalog, settings), let lo0 = e.minSeconds, let hi0 = e.maxSeconds else { return ComposerBar.lengthRange(catalog?.tier(d.quality)) }
        let lo = Swift.max(1, Int(lo0.rounded(.up)))
        return lo...Swift.max(lo, Int(hi0.rounded(.down)))
    }

    /// Only these lengths (Veo 3.1 Lite: 4, 6, 8), or nil for any whole second in the range.
    public static func allowedLengths(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> [Int]? {
        guard let a = pinned(d, catalog, settings)?.allowedSeconds, !a.isEmpty else { return nil }
        return a.map { Int($0.rounded()) }.sorted()
    }

    /// The shapes on offer: the pinned model's, else the catalog's.
    public static func aspects(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> [String] {
        if let e = pinned(d, catalog, settings), !e.aspectRatios.isEmpty { return e.aspectRatios }
        let listed = catalog?.aspectRatios ?? []
        return listed.isEmpty ? ComposerBar.shapes : listed
    }

    /// The draft inside the pinned model's limits: the length clamped (and snapped to an allowed value), the shape kept
    /// when the model makes it, else 9:16 when it can, else its first.
    public static func fitted(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> ComposerDraft {
        var x = d
        let r = lengthRange(d, catalog: catalog, settings: settings)
        x.duration = Swift.min(Swift.max(d.duration, r.lowerBound), r.upperBound)
        if let allowed = allowedLengths(d, catalog: catalog, settings: settings) {
            x.duration = allowed.min { abs($0 - x.duration) < abs($1 - x.duration) } ?? x.duration
        }
        let shapes = aspects(d, catalog: catalog, settings: settings)
        if !shapes.isEmpty, !shapes.contains(x.aspect) { x.aspect = shapes.contains("9:16") ? "9:16" : shapes[0] }
        return x
    }

    /// Pins a video model at a resolution (nil = Auto, the quality's ladder), then fits the draft to it. Without a
    /// resolution: the one its ladder runs it at, else its best.
    public static func pin(_ d: ComposerDraft, _ e: SuiteModelOption?, resolution: String? = nil, catalog: SuiteCatalog?, settings: SuiteSettings?) -> ComposerDraft {
        var x = d
        x.engineModel = e?.model
        x.resolution = e.flatMap { e in resolution.flatMap { r in e.resolutions.contains { $0.id == r } ? r : nil } ?? e.resolution ?? e.resolutions.last?.id }
        return fitted(x, catalog: catalog, settings: settings)
    }

    /// A pin survives a quality change or a reload while the owner's list still offers it for this tool. Without the
    /// list (a member never has one) the tier rules apply as before.
    public static func validated(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> ComposerDraft {
        guard let e = d.engineModel else { return d }
        let list = engines(catalog, settings)
        if list.isEmpty { return ComposerEngines.validated(d, catalog) }
        guard let m = list.first(where: { $0.model == e }), supports(m, tool: d.tool) || !offered(d.tool) else {
            return pin(d, nil, catalog: catalog, settings: settings)
        }
        return fitted(d, catalog: catalog, settings: settings)
    }

    /// What the shot's input slots follow: the pinned model's, else the tier's.
    public static func inputs(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> SuiteInputs {
        if let i = pinned(d, catalog, settings)?.inputs { return i }
        return d.inputs(catalog)
    }

    // MARK: Photo (the photo request's `imageModel`)

    /// The pinned image model, while the owner's list still has it.
    public static func pinnedImage(_ photo: PhotoDraft, _ catalog: SuiteCatalog?) -> SuiteModelOption? {
        guard let id = photo.imageModel else { return nil }
        return (catalog?.engines ?? []).first { $0.model == id && $0.kind == "image" }
    }

    /// Drops an image pin the list no longer has.
    public static func validatedImage(_ photo: PhotoDraft, _ catalog: SuiteCatalog?) -> PhotoDraft {
        guard photo.imageModel != nil, catalog?.engines != nil, pinnedImage(photo, catalog) == nil else { return photo }
        var p = photo
        p.imageModel = nil
        return p
    }

    // MARK: Words (owner only)

    /// The pill: "Auto" or "Kling 4.0, 1080p" (a photo model: its name).
    public static func label(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> String {
        guard let id = d.engineModel else { return "Auto" }
        let e = pinned(d, catalog, settings)
        let name = e?.name ?? catalog?.tier(d.quality)?.models?.first { $0.model == id }?.name ?? id
        let res = e?.resolutions.first { $0.id == d.resolution }?.label ?? d.resolution
        return res.map { "\(name), \(resLabel($0))" } ?? name
    }

    public static func imageLabel(_ photo: PhotoDraft, catalog: SuiteCatalog?) -> String {
        guard let id = photo.imageModel else { return "Auto" }
        return pinnedImage(photo, catalog)?.name ?? id
    }

    /// "720p · standard" → "720p": the first word of the provider's label.
    public static func resLabel(_ s: String) -> String { String(s.split(separator: " ").first ?? Substring(s)) }

    /// "4–15 s, 6 shapes" or "4, 6 or 8 s, 9:16 and 16:9"; an image model: its shapes, or nothing.
    public static func limits(_ e: SuiteModelOption) -> String {
        var parts: [String] = []
        if let a = e.allowedSeconds, !a.isEmpty {
            let v = a.map { "\(Int($0.rounded()))" }
            parts.append(v.count == 1 ? "\(v[0]) s" : v.dropLast().joined(separator: ", ") + " or \(v.last!) s")
        } else if let lo = e.minSeconds, let hi = e.maxSeconds {
            parts.append("\(Int(lo.rounded(.up)))–\(Int(hi.rounded(.down))) s")
        }
        let a = e.aspectRatios
        if a.count == 1 { parts.append("\(a[0]) only") } else if a.count == 2 { parts.append("\(a[0]) and \(a[1])") } else if a.count > 2 { parts.append("\(a.count) shapes") }
        return parts.joined(separator: ", ")
    }

    /// "$0.08/s" at this resolution, "$0.05 a photo", "$0.40 a run", or "" when the price is unknown.
    public static func price(_ e: SuiteModelOption, resolution: String? = nil) -> String {
        if let r = resolution, let p = e.resolutions.first(where: { $0.id == r })?.perSec { return perSecond(p) }
        if let run = e.perRun { return money(run) + (e.kind == "image" ? " a photo" : " a run") }
        if let p = e.perSec { return perSecond(p) }
        return ""
    }

    static func perSecond(_ p: Double) -> String { (p >= 0.1 ? String(format: "$%.2f", p) : String(format: "$%.3f", p)) + "/s" }
    static func money(_ p: Double) -> String { p >= 0.1 ? String(format: "$%.2f", p) : String(format: "$%.3f", p) }
}
