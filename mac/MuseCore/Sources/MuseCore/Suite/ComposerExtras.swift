import Foundation

// AI suite (workstream 1): the composer's later pieces (plans/video-composer.md), pure so they are unit-tested:
// Recast's "tap a face" maths, Character swap's add-on pills, the Era decade slider, UGC ad's format wheel, @locations
// (the locations library and their reference images) and the owner's per-shot engine pin. No layout.

// MARK: Recast · tap a face

/// A tap on the clip's first frame: 0…1 from the left and from the top.
public struct FacePoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

/// A rectangle in pixels (origin top left).
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum RecastFaces {
    /// The crop's side as a share of the frame's short side.
    public static let cropShare = 0.28
    /// How close (in 0…1 of the frame's width) a click must be to a marker to pick it.
    public static let markerRadius = 0.06

    /// Where the person stands, by horizontal third.
    public static func hint(x: Double) -> String {
        if x < 1.0 / 3 { return "left" }
        if x < 2.0 / 3 { return "center" }
        return "right"
    }

    /// The hint a tap sets: the chip the user picked wins, else the third the face is in.
    public static func hint(for tap: FacePoint, chosen: String?) -> String { chosen ?? hint(x: tap.x) }

    /// A square around the tap, its side `cropShare` of the short side, moved (not shrunk) to stay inside the frame.
    public static func cropRect(_ tap: FacePoint, width: Int, height: Int, share: Double = cropShare) -> PixelRect {
        let short = max(1, min(width, height))
        let side = min(short, max(1, Int((Double(short) * share).rounded())))
        let cx = tap.x * Double(width), cy = tap.y * Double(height)
        let x = min(max(Int((cx - Double(side) / 2).rounded()), 0), max(0, width - side))
        let y = min(max(Int((cy - Double(side) / 2).rounded()), 0), max(0, height - side))
        return PixelRect(x: x, y: y, width: side, height: side)
    }

    /// The marker a click lands on (its index), or nil for a new face.
    public static func marker(at p: FacePoint, in marks: [FacePoint?], aspect: Double = 9.0 / 16, radius: Double = markerRadius) -> Int? {
        var best: (Int, Double)?
        for (i, m) in marks.enumerated() {
            guard let m else { continue }
            let dx = p.x - m.x, dy = (p.y - m.y) / max(aspect, 0.01)
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= radius, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// Two tapped faces in the same third would read as the same person: those get `personIndex`, their order from the
    /// left among the tapped faces (1-based). Everyone else is left as is.
    public static func resolveClashes(_ cast: [CastMember], faces: [FacePoint?]) -> [CastMember] {
        let tapped = cast.indices.filter { $0 < faces.count && faces[$0] != nil }
        let order = tapped.sorted { faces[$0]!.x < faces[$1]!.x }
        var out = cast
        for i in tapped {
            guard let h = cast[i].personHint else { continue }
            let clash = cast.indices.contains { $0 != i && cast[$0].personHint == h && cast[$0].personIndex == nil }
            if clash, let rank = order.firstIndex(of: i) { out[i].personIndex = min(rank + 1, 4) }
        }
        return out
    }
}

// MARK: Character swap · add-on pills

/// An add-on pill on the swap tool: Edit, Fast · beta (only when available) and Upscale (coming soon today). The price
/// is the add-on's own, from the studio's estimate path (`Pricing.totalCost` of its render); Quality stays the main ladder.
public struct SwapAddOnPill: Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String
    public var available: Bool
    public var comingSoon: Bool
    /// Edit / Fast · beta: the render it makes. nil for Upscale.
    public var quality: VideoQuality?
    public var price: Double?

    /// "about $0.67", "Soon", or "—".
    public var priceText: String {
        if comingSoon || !available { return "Soon" }
        return price.map { "about " + Pricing.money($0) } ?? "—"
    }
}

public enum SwapAddOns {
    public static func pills(_ f: VideoFeatures, clipSeconds: Double?, takes: Int = 1, lipSync: Bool = false) -> [SwapAddOnPill] {
        f.shownAddons.map { a -> SwapAddOnPill in
            let q = a.videoQuality
            let price: Double? = q.map { Pricing.totalCost(RenderSpec.addOn($0, clipSeconds: clipSeconds, takes: takes, lipSync: lipSync)) }
                ?? a.sizes.filter(\.available).compactMap(\.price).min()
            return SwapAddOnPill(id: a.id, label: a.label, detail: a.shownDetail, available: a.available && !a.comingSoon, comingSoon: a.comingSoon,
                                 quality: q, price: price)
        }
    }

    /// Tapping a pill: it turns on (only one add-on at a time), tapping it again turns it off (back to the ladder).
    /// Upscale and unavailable add-ons don't turn on.
    public static func toggle(_ current: VideoQuality?, _ pill: SwapAddOnPill) -> VideoQuality? {
        guard pill.available, let q = pill.quality else { return current }
        return current == q ? nil : q
    }
}

// MARK: Style · Era as a decade slider

/// The Era slider: Auto off the left end, then the catalog's eras in order (1960s … 2020s, Near future).
public enum ComposerEras {
    public static func stops(_ c: CameraCatalog) -> [SuiteOption] { ComposerCatalog.visible(c.eras) }

    /// The slider's position for an era: 0 = Auto, else its place + 1 (a merged id sits on its survivor).
    public static func position(_ era: String?, _ c: CameraCatalog) -> Int {
        guard let s = ComposerCatalog.survivor(c.eras, era) else { return 0 }
        return (stops(c).firstIndex { $0.id == s }).map { $0 + 1 } ?? 0
    }

    /// The era at a slider value, snapped to the nearest stop; nil = Auto.
    public static func era(at value: Double, _ c: CameraCatalog) -> String? {
        let list = stops(c)
        let i = min(max(Int(value.rounded()), 0), list.count)
        return i == 0 ? nil : list[i - 1].id
    }

    public static func label(at position: Int, _ c: CameraCatalog) -> String {
        let list = stops(c)
        return position <= 0 || position > list.count ? "Auto" : list[position - 1].label
    }

    /// The slider's last position.
    public static func maxPosition(_ c: CameraCatalog) -> Int { stops(c).count }
}

// MARK: UGC ad · format wheel

extension ComposerWheels {
    /// The UGC format wheel: Auto, then the catalog's formats.
    public static func formats(_ c: CameraCatalog) -> [WheelItem] {
        [.auto("Picks the format from your prompt")] + ComposerCatalog.visible(c.ugcFormats).map { WheelItem(value: $0.id, name: $0.label, caption: $0.description) }
    }
}

// MARK: @location

/// GET /v1/suite/locations: a place saved to the studio, used in a prompt as @name.
public struct SuiteLocation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var image: ImageRef
    /// Milliseconds since 1970 (an ISO date is read too).
    public var createdAt: Double

    public init(id: String, name: String, image: ImageRef, createdAt: Double = 0) {
        self.id = id
        self.name = name
        self.image = image
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, name, image, createdAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.v(.name, id)
        image = c.v(.image, ImageRef())
        if let n: Double = c.o(.createdAt) {
            createdAt = n
        } else if let s: String = c.o(.createdAt), let date = ISO8601DateFormatter().date(from: s) {
            createdAt = (date.timeIntervalSince1970 * 1000).rounded()
        } else {
            createdAt = 0
        }
    }
}

/// POST /v1/suite/locations.
public struct NewSuiteLocation: Codable, Hashable, Sendable {
    public var name: String
    public var image: ImageRef
    public init(name: String, image: ImageRef) {
        self.name = name
        self.image = image
    }
}

public enum ComposerLocations {
    /// The longest name a location can have.
    public static let maxName = 40

    /// The prompt's @locations, in order.
    public static func ids(_ tokens: PromptTokens) -> [String] {
        tokens.mentions.compactMap(\.mentionInfo).filter { $0.kind == "location" }.map(\.id)
    }

    /// How many reference images the shot uses: filled reference slots plus @locations.
    public static func used(_ tokens: PromptTokens, slots: InputSlots) -> Int {
        slots.values.keys.filter { $0.kind == .image }.count + ids(tokens).count
    }

    /// nil when a location can go in, else the line to show (References full, or none on this quality).
    public static func refusal(_ tokens: PromptTokens, slots: InputSlots, inputs: SuiteInputs) -> String? {
        let cap = SlotKind.image.capacity(inputs)
        if cap == 0 { return "This quality doesn't take references · try Standard or HD" }
        let n = used(tokens, slots: slots)
        return n >= cap ? "References are full (\(n)/\(cap)) · remove one to add a location" : nil
    }

    /// Adds an @location, or refuses it (with the line) when the References limit is reached.
    public static func add(_ loc: SuiteLocation, to tokens: PromptTokens, at caret: Caret? = nil, slots: InputSlots, inputs: SuiteInputs) -> (PromptTokens, String?) {
        if ids(tokens).contains(loc.id) { return (tokens, "\(loc.name) is already in the shot") }
        if let no = refusal(tokens, slots: slots, inputs: inputs) { return (tokens, no) }
        return tokens.addMention(kind: "location", id: loc.id, label: loc.name, at: caret)
    }

    /// `references.images += {image, role: "location", label: name}` for each @location the library knows, while the
    /// quality's References limit has room after the reference slots.
    public static func apply(_ r: ShotRequest, tokens: PromptTokens, locations: [SuiteLocation], inputs: SuiteInputs) -> ShotRequest {
        let wanted = ids(tokens).compactMap { id in locations.first { $0.id == id } }
        guard !wanted.isEmpty else { return r }
        var out = r
        var refs = out.references ?? SuiteReferences()
        var images = refs.images ?? []
        let room = max(0, SlotKind.image.capacity(inputs) - images.count)
        for l in wanted.prefix(room) { images.append(SuiteRefImage(image: l.image, role: "location", label: String(l.name.prefix(80)))) }
        guard !images.isEmpty else { return r }
        refs.images = images
        out.references = refs
        return out
    }

    /// A tidy name for a new location ("  rooftop   bar " → "Rooftop bar"), nil when empty.
    public static func cleanName(_ s: String) -> String? {
        let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !t.isEmpty else { return nil }
        let n = String(t.prefix(maxName))
        return n.prefix(1).uppercased() + n.dropFirst()
    }
}

// MARK: The owner's engine pin

public enum ComposerEngines {
    /// The engines the owner can pin on a tier (its `models`, in ladder order).
    public static func options(_ tier: SuiteTier?) -> [SuiteTierModel] { tier?.models ?? [] }

    /// "Engine · Auto" or "Engine · Kling 4.0 · 1080p".
    public static func label(_ d: ComposerDraft, _ tier: SuiteTier?) -> String {
        guard let e = d.engineModel else { return "Engine · Auto" }
        let m = options(tier).first { $0.model == e && (d.resolution == nil || $0.resolution == d.resolution) }
        let res = d.resolution ?? m?.resolution
        return "Engine · \(m?.name ?? e)" + (res.map { " · \($0)" } ?? "")
    }

    /// Pins an engine (nil = Auto).
    public static func pin(_ d: ComposerDraft, _ m: SuiteTierModel?) -> ComposerDraft {
        var x = d
        x.engineModel = m?.model
        x.resolution = m?.resolution
        return x
    }

    /// After the quality changes: a pin the new tier doesn't run is dropped (back to Auto).
    public static func validated(_ d: ComposerDraft, _ catalog: SuiteCatalog?) -> ComposerDraft {
        guard let e = d.engineModel else { return d }
        let ok = options(catalog?.tier(d.quality)).contains { $0.model == e && (d.resolution == nil || $0.resolution == d.resolution) }
        return ok ? d : pin(d, nil)
    }
}
