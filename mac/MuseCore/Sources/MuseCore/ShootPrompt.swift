import Foundation

// Shoot references and the server-built photoshoot prompt (plans/api.md "Shoot references and the prompt library", 2026-11-05).

/// What a reference image guides. There is no outfit guide: her face and body always come from her own references.
public enum ShootGuide: String, Codable, CaseIterable, Hashable, Sendable {
    case pose, look, scene

    public var label: String {
        switch self {
        case .pose: return "Pose & framing"
        case .look: return "Look & colour"
        case .scene: return "Scene"
        }
    }
}

/// One reference image of a photoshoot (up to `ShootRef.max`), with 1–3 guides.
public struct ShootRef: Codable, Hashable, Sendable {
    public static let max = 3

    public var image: ImageRef
    public var guides: [ShootGuide]

    public init(image: ImageRef, guides: [ShootGuide] = [.pose]) {
        self.image = image
        self.guides = guides
    }

    enum CodingKeys: String, CodingKey { case image, guides }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        image = c.v(.image, ImageRef())
        // Unknown guides from a newer server are skipped rather than failing the whole take.
        let raw: [String] = c.v(.guides, [])
        guides = raw.compactMap(ShootGuide.init(rawValue:))
    }

    /// Turns a guide on or off; the last one on stays on (a reference needs at least one).
    public mutating func toggle(_ g: ShootGuide) {
        if let i = guides.firstIndex(of: g) {
            if guides.count > 1 { guides.remove(at: i) }
        } else {
            guides.append(g)
            guides.sort { ShootGuide.allCases.firstIndex(of: $0)! < ShootGuide.allCases.firstIndex(of: $1)! }
        }
    }

    /// What `POST /v1/shoots` accepts: 1–3 guides, no repeats, an image.
    public var isValid: Bool { !guides.isEmpty && guides.count == Set(guides).count && (image.url != nil || image.asset != nil) }

    /// The guide a new reference starts with: the first one the other references don't use yet.
    public static func defaultGuide(after existing: [ShootRef]) -> ShootGuide {
        let used = Set(existing.flatMap(\.guides))
        return ShootGuide.allCases.first { !used.contains($0) } ?? .pose
    }
}

/// `features.photo.references`: how many reference images and which guides.
public struct ShootReferencesFeature: Codable, Hashable, Sendable {
    public struct Guide: Codable, Hashable, Sendable {
        public var id: String
        public var label: String
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public var max: Int
    public var guides: [Guide]

    public init(max: Int = ShootRef.max, guides: [Guide] = ShootGuide.allCases.map { Guide(id: $0.rawValue, label: $0.label) }) {
        self.max = max
        self.guides = guides
    }

    enum CodingKeys: String, CodingKey { case max, guides }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = ShootReferencesFeature()
        max = c.v(.max, z.max)
        guides = c.v(.guides, z.guides)
    }

    /// The label for a guide (the server's when it sends one).
    public func label(_ g: ShootGuide) -> String { guides.first { $0.id == g.rawValue }?.label ?? g.label }
}

/// `ShootRequest.camera`.
public struct ShootCamera: Codable, Hashable, Sendable {
    public var shot: String
    public var lens: Int
    public var aperture: String
    public init(shot: String, lens: Int, aperture: String) {
        self.shot = shot
        self.lens = lens
        self.aperture = aperture
    }
}

/// One reference image in a preview: its image number in what is sent, or dropped (the shot model can't take it).
public struct ShootPreviewRef: Codable, Hashable, Sendable {
    public var index: Int?
    public var guides: [ShootGuide]
    public var dropped: Bool

    public init(index: Int?, guides: [ShootGuide], dropped: Bool = false) {
        self.index = index
        self.guides = guides
        self.dropped = dropped
    }

    enum CodingKeys: String, CodingKey { case index, guides, dropped }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        index = c.o(.index)
        let raw: [String] = c.v(.guides, [])
        guides = raw.compactMap(ShootGuide.init(rawValue:))
        dropped = c.v(.dropped, false)
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(guides, forKey: .guides)
        if dropped { try c.encode(true, forKey: .dropped) }
    }
}

/// `POST /v1/shoots/preview` → the final prompt, the images that will be sent and the price. Free.
public struct ShootPreview: Codable, Hashable, Sendable {
    public var slots: [PromptSlotView]
    /// Exactly what `POST /v1/shoots` will send.
    public var text: String
    public var seed: Int64?
    /// Direction clauses that were dropped (they would change her identity or add a never-add item).
    public var removed: [String]
    public var images: Int
    public var refs: [ShootPreviewRef]
    public var estimate: Double
    public var estimateLabel: String
    /// True when "prompt" (Edit as text) was sent.
    public var edited: Bool

    public init(slots: [PromptSlotView], text: String? = nil, seed: Int64? = nil, removed: [String] = [], images: Int = 0, refs: [ShootPreviewRef] = [],
                estimate: Double = 0, estimateLabel: String? = nil, edited: Bool = false) {
        self.slots = slots
        self.text = text ?? slots.map(\.text).joined(separator: "\n")
        self.seed = seed
        self.removed = removed
        self.images = images
        self.refs = refs
        self.estimate = estimate
        self.estimateLabel = estimateLabel ?? PhotoPricing.label(estimate)
        self.edited = edited
    }

    enum CodingKeys: String, CodingKey { case slots, text, seed, removed, images, refs, estimate, estimateLabel, edited }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slots = c.v(.slots, [])
        text = c.v(.text, slots.map(\.text).joined(separator: "\n"))
        seed = c.o(.seed)
        removed = c.v(.removed, [])
        images = c.v(.images, 0)
        refs = c.v(.refs, [])
        estimate = c.v(.estimate, 0)
        estimateLabel = c.v(.estimateLabel, PhotoPricing.label(estimate))
        edited = c.v(.edited, false)
    }

    /// Reference images the shot model can't take (shown as "not sent").
    public var droppedRefs: Int { refs.filter(\.dropped).count }
}

extension ShootRequest {
    /// A photoshoot without a template: the user's choices, and the server builds the prompt (plans/api.md 2026-11-05 §2).
    /// `prompt` only for "Edit as text" (sent to the model exactly). Lock look sends `lockSeed` and the server fixes the seed.
    public static func built(modelId: String, outfitId: String, settings s: ShootSettings, presets: Bool, refs: [ShootRef], prompt: String? = nil,
                             count: Int = PhotoPricing.shootCount) -> ShootRequest {
        var r = ShootRequest(modelId: modelId, outfitId: outfitId, scene: s.effectiveScene, prompt: nil, count: count)
        r.presets = presets
        r.camera = ShootCamera(shot: s.shot, lens: s.lens, aperture: s.aperture)
        r.light = s.light
        r.grade = s.grade
        let d = s.direction.trimmingCharacters(in: .whitespacesAndNewlines)
        r.direction = d.isEmpty ? nil : String(d.prefix(500))
        r.lockSeed = s.lockSeed
        r.refs = refs.isEmpty ? nil : Array(refs.prefix(ShootRef.max))
        if let p = prompt, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { r.prompt = String(p.prefix(4000)) }
        return r
    }

    /// `bad_request` reasons the server would give for `refs` (nil when fine).
    public var refsProblem: String? {
        guard let refs else { return nil }
        if refs.count > ShootRef.max { return "Up to \(ShootRef.max) reference images" }
        if refs.contains(where: { !$0.isValid }) { return "Each reference image needs an image and at least one guide" }
        return nil
    }
}

extension PromptEngine {
    /// The reference-image lines (one `reference` slot per sent image), worded like the server library's defaults.
    /// `firstIndex` = the image number of the first reference (after her identity/outfit references).
    public static func referenceSlots(_ refs: [ShootRef], firstIndex: Int) -> [PromptSlotView] {
        refs.enumerated().map { i, r in referenceSlot(r.guides, index: firstIndex + i) }
    }

    /// One reference line: its guide lines in the order pose, look, scene, then the guard line, with `index` = its image number.
    public static func referenceSlot(_ guides: [ShootGuide], index k: Int) -> PromptSlotView {
        var parts: [String] = []
        for g in ShootGuide.allCases where guides.contains(g) {
            switch g {
            case .pose: parts.append("Copy the pose and framing from image \(k).")
            case .look: parts.append("Copy the light, colour grade and camera feel from image \(k).")
            case .scene: parts.append("Use the place and background from image \(k).")
            }
        }
        parts.append("Do not take the face, body, hair or clothes from image \(k).")
        return PromptSlotView(layer: "reference", text: parts.joined(separator: " "))
    }

    /// The demo/offline stand-in for `POST /v1/shoots/preview`: the same layers the server builds from its default library.
    /// `identityImages` = her identity/outfit references sent before the reference images (at most `maxRefs`).
    public static func shootPreview(identity: PromptIdentity, outfitName: String, settings: ShootSettings, presets: Bool, refs: [ShootRef],
                                    prompt: String? = nil, houseStyle: String = houseStyle, pricing: PhotoPricing = .standard,
                                    identityImages: Int? = nil, count: Int = PhotoPricing.shootCount) -> ShootPreview {
        let idImages = min(identityImages ?? pricing.maxRefs, pricing.maxRefs)
        let maxIn = max(1, pricing.maxInputs)
        // Identity references give way first (never the face front), then the last reference images.
        let sentRefs = min(refs.count, max(0, maxIn - 1))
        let sentId = min(idImages, maxIn - sentRefs)
        let images = sentId + sentRefs
        var previewRefs: [ShootPreviewRef] = []
        for (i, r) in refs.enumerated() {
            previewRefs.append(i < sentRefs ? ShootPreviewRef(index: sentId + i + 1, guides: r.guides) : ShootPreviewRef(index: nil, guides: r.guides, dropped: true))
        }
        let estimate = pricing.shoot(count: count, images: images)
        if let p = prompt, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ShootPreview(slots: [PromptSlotView(layer: "custom", text: p)], text: p, images: images, refs: previewRefs, estimate: estimate, edited: true)
        }
        let sent = previewRefs.compactMap { r in r.index.map { (guides: r.guides, index: $0) } }
        let b = shootSlots(identity: identity, outfitName: outfitName, settings: settings, presets: presets, refs: sent, houseStyle: houseStyle)
        return ShootPreview(slots: b.slots, seed: settings.lockSeed ? seedFor(identity.name) : nil, removed: b.removed, images: images, refs: previewRefs,
                            estimate: estimate)
    }

    /// The photoshoot layers as the server builds them from its default library (shared fixture `shoot_prompt_fixture.json`):
    /// the direction is sanitised, reference lines (with their image numbers) follow it, presets off keeps identity, outfit,
    /// direction, reference and seed.
    public static func shootSlots(identity: PromptIdentity, outfitName: String, settings: ShootSettings, presets: Bool,
                                  refs: [(guides: [ShootGuide], index: Int)], houseStyle: String = houseStyle) -> (slots: [PromptSlotView], removed: [String]) {
        let (clean, removed) = sanitizeDirection(settings.direction, identity)
        var s = settings
        s.direction = clean
        // The server library's wording (the desktop prototype said "retakes" in the seed line).
        var built = shoot(identity: identity, outfitName: outfitName, settings: s, houseStyle: houseStyle).map { slot in
            PromptSlotView(layer: slot.key, text: slot.key == "seed" && s.lockSeed ? "Seed: locked (variations keep the same look)." : slot.text)
        }
        if !presets { built = built.filter { ["identity", "outfit", "direction", "seed"].contains($0.layer) } }
        let refSlots = refs.map { referenceSlot($0.guides, index: $0.index) }
        let at = (built.firstIndex { $0.layer == "direction" }).map { $0 + 1 } ?? (built.firstIndex { ["style", "negative", "seed"].contains($0.layer) } ?? built.count)
        built.insert(contentsOf: refSlots, at: at)
        return (built, removed)
    }

    /// Words that would change who she is. A direction clause containing one is dropped (as on the server and Android).
    static let identityOverride = try! NSRegularExpression(
        pattern: "\\b(blonde|brunette|redhead|ginger|bald|(blue|green|brown|hazel|grey|gray) eyes|eye colou?r|hair colou?r|dyed hair|skin tone|different (face|person|woman|girl|model)|another (face|person|woman|model)|older|younger|look like)\\b",
        options: [.caseInsensitive])

    /// "Direction never overrides identity or never-add": the cleaned direction and the dropped clauses.
    public static func sanitizeDirection(_ direction: String, _ identity: PromptIdentity) -> (clean: String, removed: [String]) {
        let raw = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return ("", []) }
        let never = neverList(identity).map(stem)
        let clauses = split(raw, pattern: "(?<=[,.;])\\s*|\\s+and\\s+(?=with\\b)").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var kept: [String] = []
        var removed: [String] = []
        for c in clauses {
            let words = c.lowercased()
            let hitsNever = never.contains { n in words.range(of: "\\b" + NSRegularExpression.escapedPattern(for: n), options: .regularExpression) != nil }
            let overrides = identityOverride.firstMatch(in: c, range: NSRange(c.startIndex..., in: c)) != nil
            if hitsNever || overrides { removed.append(trimEnd(c, ",;.").trimmingCharacters(in: .whitespaces)) } else { kept.append(c) }
        }
        if removed.isEmpty { return (raw, []) }
        return (trimEnd(kept.joined(separator: " ").trimmingCharacters(in: .whitespaces), ",;").trimmingCharacters(in: .whitespaces), removed)
    }

    /// Singular stem for matching "rings" against "ring".
    static func stem(_ s: String) -> String {
        let w = s.lowercased().trimmingCharacters(in: .whitespaces)
        if w.hasSuffix("ies") { return String(w.dropLast(3)) }
        if w.hasSuffix("ches") || w.hasSuffix("shes") || w.hasSuffix("xes") { return String(w.dropLast(2)) }
        if w.hasSuffix("s") && !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }

    static func trimEnd(_ s: String, _ chars: String) -> String {
        var out = Substring(s)
        while let last = out.last, chars.contains(last) { out = out.dropLast() }
        return String(out)
    }

    /// String.split with a regex like JavaScript's (empty matches split too; no empty piece at the start).
    static func split(_ s: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [s] }
        let ns = s as NSString
        var out: [String] = []
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.length == 0 && m.range.location == 0 { continue }
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }

    /// Java's String.hashCode, so Lock look gives the same seed as the server and the Android app.
    public static func seedFor(_ key: String) -> Int64 {
        var h: Int32 = 0
        for u in key.utf16 { h = h &* 31 &+ Int32(u) }
        return Int64(Int(h) & 0x7fffffff) % 1_000_000
    }
}

extension PhotoPricing {
    /// A photoshoot of `count` photos that sends `images` input images in all (identity references + reference images).
    public func shoot(count: Int, images: Int) -> Double {
        Double(count) * (perRun + perOutputMp * PhotoPricing.shootOutMp + perInputMp * refMp * Double(min(max(0, images), maxInputs)))
    }
}
