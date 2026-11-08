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

// MARK: The picker

public enum ComposerModelPicker {
    /// Picked for this tool from the whole registry: switched on, not blocked or removed, its provider set up, and a
    /// video model that can make this tool's shot (text, a start frame or references; Recast needs `recast`).
    public static func usable(_ m: SuiteRegistryModel) -> Bool {
        m.enabled && !m.blocked && m.status != "removed" && m.configured && !m.needsAck && m.kind == "video" && !m.resolutions.isEmpty
    }

    public static func supports(_ m: SuiteRegistryModel, tool: ComposerTool) -> Bool {
        switch tool {
        case .shot, .storyboard: return m.modes.text || m.modes.image || m.modes.reference
        case .talking: return (m.modes.text || m.modes.reference) && m.refs.audios > 0
        case .ugc: return m.modes.reference && m.refs.images > 0
        case .recast: return m.modes.recast
        case .swap, .extend, .photo: return false
        }
    }

    /// Whether the picker shows for this tool (Swap runs on its add-on, Extend on its own ladder, Photo has no per-shot
    /// image model on the server yet).
    public static func offered(_ tool: ComposerTool) -> Bool {
        switch tool {
        case .shot, .talking, .ugc, .storyboard: return true
        case .swap, .recast, .extend, .photo: return false
        }
    }

    /// The models to offer: the quality's ladder first (its order), then every other usable model by name; the owner's
    /// own provider models (`custom`) last. A search filters by name, id or provider.
    public static func options(_ settings: SuiteSettings?, tool: ComposerTool, tier: SuiteTier?, search: String = "") -> [SuiteRegistryModel] {
        let all = (settings?.models ?? []).filter { usable($0) && supports($0, tool: tool) }
        let ladder = (tier?.models ?? []).map(\.model)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let found = q.isEmpty ? all : all.filter { "\($0.name) \($0.id) \($0.provider)".lowercased().contains(q) }
        return found.sorted { a, b in
            let ia = ladder.firstIndex(of: a.id) ?? Int.max, ib = ladder.firstIndex(of: b.id) ?? Int.max
            if a.custom != b.custom { return !a.custom }
            if ia != ib { return ia < ib }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The pinned model, when there is one in the registry.
    public static func pinned(_ d: ComposerDraft, _ settings: SuiteSettings?) -> SuiteRegistryModel? {
        guard let id = d.engineModel else { return nil }
        return settings?.models.first { $0.id == id }
    }

    /// The Length range: the pinned model's, else the quality's.
    public static func lengthRange(_ d: ComposerDraft, tier: SuiteTier?, settings: SuiteSettings?) -> ClosedRange<Int> {
        guard let du = pinned(d, settings)?.duration else { return ComposerBar.lengthRange(tier) }
        let lo = Swift.max(1, Int(du.min.rounded(.up)))
        return lo...Swift.max(lo, Int(du.max.rounded(.down)))
    }

    /// Only these lengths (Veo 3.1 Lite: 4, 6, 8), or nil for any whole second in the range.
    public static func allowedLengths(_ d: ComposerDraft, settings: SuiteSettings?) -> [Int]? {
        guard let a = pinned(d, settings)?.duration?.allowed, !a.isEmpty else { return nil }
        return a.map { Int($0.rounded()) }.sorted()
    }

    /// The shapes on offer: the pinned model's, else the catalog's.
    public static func aspects(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> [String] {
        if let m = pinned(d, settings), !m.aspectRatios.isEmpty { return m.aspectRatios }
        let listed = catalog?.aspectRatios ?? []
        return listed.isEmpty ? ComposerBar.shapes : listed
    }

    /// The draft inside the pinned model's limits: the length clamped (and snapped to an allowed value), the shape kept
    /// when the model makes it, else 9:16 when it can, else its first.
    public static func fitted(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> ComposerDraft {
        var x = d
        let tier = catalog?.tier(d.quality)
        let r = lengthRange(d, tier: tier, settings: settings)
        x.duration = Swift.min(Swift.max(d.duration, r.lowerBound), r.upperBound)
        if let allowed = allowedLengths(d, settings: settings) {
            x.duration = allowed.min { abs($0 - x.duration) < abs($1 - x.duration) } ?? x.duration
        }
        let shapes = aspects(d, catalog: catalog, settings: settings)
        if !shapes.isEmpty, !shapes.contains(x.aspect) { x.aspect = shapes.contains("9:16") ? "9:16" : shapes[0] }
        return x
    }

    /// Pins a model at a resolution (nil = Auto, the quality's ladder), then fits the draft to it.
    public static func pin(_ d: ComposerDraft, _ m: SuiteRegistryModel?, resolution: String? = nil, catalog: SuiteCatalog?, settings: SuiteSettings?) -> ComposerDraft {
        var x = d
        x.engineModel = m?.id
        x.resolution = m.map { m in resolution.flatMap { r in m.resolutions.contains { $0.id == r } ? r : nil } ?? m.resolutions.last?.id } ?? nil
        return fitted(x, catalog: catalog, settings: settings)
    }

    /// A pin survives a quality change or a reload when the tier lists it or the registry still offers it for this tool.
    public static func validated(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> ComposerDraft {
        guard let e = d.engineModel else { return d }
        if let m = settings?.models.first(where: { $0.id == e }) {
            return usable(m) && supports(m, tool: d.tool) ? fitted(d, catalog: catalog, settings: settings) : pin(d, nil, catalog: catalog, settings: settings)
        }
        return ComposerEngines.validated(d, catalog)
    }

    /// What the shot's input slots follow: the pinned registry model's, else the tier's (or its ladder engine's).
    public static func inputs(_ d: ComposerDraft, catalog: SuiteCatalog?, settings: SuiteSettings?) -> SuiteInputs {
        let tier = catalog?.tier(d.quality)
        if let e = d.engineModel, tier?.models?.contains(where: { $0.model == e }) != true, let m = pinned(d, settings) { return m.inputs }
        return d.inputs(catalog)
    }

    // MARK: Words (owner only)

    /// The pill: "Auto" or "Kling 4.0, 1080p".
    public static func label(_ d: ComposerDraft, settings: SuiteSettings?, tier: SuiteTier?) -> String {
        guard let e = d.engineModel else { return "Auto" }
        let name = pinned(d, settings)?.name ?? tier?.models?.first { $0.model == e }?.name ?? e
        let res = pinned(d, settings)?.resolutions.first { $0.id == d.resolution }?.label ?? d.resolution
        return res.map { "\(name), \(resLabel($0))" } ?? name
    }

    /// "720p · standard" → "720p": the first word of the provider's label.
    public static func resLabel(_ s: String) -> String { String(s.split(separator: " ").first ?? Substring(s)) }

    /// "4–15 s, 6 shapes" or "4, 6 or 8 s, 9:16 and 16:9".
    public static func limits(_ m: SuiteRegistryModel) -> String {
        var parts: [String] = []
        if let du = m.duration {
            if let a = du.allowed, !a.isEmpty {
                let v = a.map { "\(Int($0.rounded()))" }
                parts.append(v.count == 1 ? "\(v[0]) s" : v.dropLast().joined(separator: ", ") + " or \(v.last!) s")
            } else {
                parts.append("\(Int(du.min.rounded(.up)))–\(Int(du.max.rounded(.down))) s")
            }
        }
        let a = m.aspectRatios
        if a.count == 1 { parts.append("\(a[0]) only") } else if a.count == 2 { parts.append("\(a[0]) and \(a[1])") } else if a.count > 2 { parts.append("\(a.count) shapes") }
        return parts.joined(separator: ", ")
    }

    /// "$0.08/s" at this resolution.
    public static func price(_ m: SuiteRegistryModel, resolution: String?) -> String {
        guard let p = m.perSec(resolution) else { return "" }
        return p >= 0.1 ? String(format: "$%.2f/s", p) : String(format: "$%.3f/s", p)
    }
}
