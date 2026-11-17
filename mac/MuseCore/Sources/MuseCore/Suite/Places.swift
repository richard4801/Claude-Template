import Foundation

// Her world, phase 1 (plans/model-world.md §1, §5): places on her page (Places tab), the @ list, and priced place photos.
// Server: /v1/suite/locations (server/api/src/suite/locations.ts).

/// How a place photo was made.
public enum PlaceImageSource: String, Codable, Hashable, Sendable, CaseIterable {
    case upload, random, description, reference
    /// The caption under the photo (mockup 2).
    public var caption: String {
        switch self {
        case .upload: return "Uploaded"
        case .random: return "Generated, random view"
        case .description: return "Generated from a description"
        case .reference: return "Generated from a reference"
        }
    }
}

/// One photo of a place.
public struct PlaceImage: Codable, Hashable, Sendable {
    public var image: ImageRef
    public var source: PlaceImageSource

    public init(image: ImageRef, source: PlaceImageSource) {
        self.image = image
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case asset, url, source }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        image = ImageRef(asset: c.o(.asset), url: c.o(.url))
        source = PlaceImageSource(rawValue: c.v(.source, "upload")) ?? .upload
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(image.asset, forKey: .asset)
        try c.encodeIfPresent(image.url, forKey: .url)
        try c.encode(source.rawValue, forKey: .source)
    }
}

/// POST /v1/suite/locations for her place (no photo needed) or a studio place (a photo).
public struct NewPlace: Codable, Hashable, Sendable {
    public var name: String
    public var modelId: String?
    public var tag: String?
    public var description: String?
    public var image: ImageRef?
    public init(name: String, modelId: String?, tag: String? = nil, description: String? = nil, image: ImageRef? = nil) {
        self.name = name
        self.modelId = modelId
        self.tag = tag
        self.description = description
        self.image = image
    }
}

/// PATCH /v1/suite/locations/{id}: rename, retag, describe, pick the cover. Nil fields are left as they are.
public struct PlacePatch: Codable, Hashable, Sendable {
    public var name: String?
    public var tag: String?
    public var description: String?
    public var cover: Int?
    public init(name: String? = nil, tag: String? = nil, description: String? = nil, cover: Int? = nil) {
        self.name = name
        self.tag = tag
        self.description = description
        self.cover = cover
    }
}

/// The three ways to make a place photo (the Add photo menu).
public enum PlacePhotoMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case random, description, reference
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .random: return "A random view of this place"
        case .description: return "From a description"
        case .reference: return "From a reference picture"
        }
    }
    public var line: String {
        switch self {
        case .random: return "From its photos"
        case .description: return "Words you type, or the place’s own"
        case .reference: return "A photo you like, rebuilt here"
        }
    }
}

/// POST /v1/suite/locations/{id}/generate(/estimate). `maxUsd` = the price approved: never charged above it.
public struct PlacePhotoRequest: Codable, Hashable, Sendable {
    public var mode: PlacePhotoMode
    public var description: String?
    public var reference: ImageRef?
    public var maxUsd: Double?
    public init(mode: PlacePhotoMode, description: String? = nil, reference: ImageRef? = nil, maxUsd: Double? = nil) {
        self.mode = mode
        self.description = description
        self.reference = reference
        self.maxUsd = maxUsd
    }
}

/// The price shown before anything is made ("Generate · $0.03").
public struct PlacePhotoEstimate: Codable, Hashable, Sendable {
    public var estimate: Double
    public var buttonLabel: String
    public var priceLine: String
    public init(estimate: Double, buttonLabel: String, priceLine: String) {
        self.estimate = estimate
        self.buttonLabel = buttonLabel
        self.priceLine = priceLine
    }
    enum CodingKeys: String, CodingKey { case estimate, buttonLabel, priceLine }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        estimate = c.v(.estimate, 0)
        buttonLabel = c.v(.buttonLabel, "Generate · \(Places.money(estimate))")
        priceLine = c.v(.priceLine, "")
    }
}

/// POST /v1/suite/locations/{id}/generate → the place with its new photo, and what was charged.
public struct PlacePhotoResult: Codable, Hashable, Sendable {
    public var place: SuiteLocation
    public var chargedUsd: Double
    public init(place: SuiteLocation, chargedUsd: Double) {
        self.place = place
        self.chargedUsd = chargedUsd
    }
}

public enum Places {
    /// Photos a place keeps.
    public static let maxImages = 8
    /// The suggestions an empty Places tab offers (mockup 6).
    public static let starters = ["Apartment", "Bedroom", "Gym", "Café"]

    /// "Café by the gym" → "cafe-by-the-gym" (as the server makes it).
    public static func tag(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = "", dash = false
        for ch in folded.unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                out.unicodeScalars.append(ch)
                dash = false
            } else if !out.isEmpty && !dash {
                out += "-"
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        out = String(out.prefix(30))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "place" : out
    }

    /// A tag as typed ("@Cafe " → "cafe"), nil when it isn't one (1–30 letters, digits, - or _).
    public static func cleanTag(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("@") { t.removeFirst() }
        guard let first = t.unicodeScalars.first, t.count <= 30, ("a"..."z").contains(first) || ("0"..."9").contains(first) else { return nil }
        let ok = t.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
        return ok ? t : nil
    }

    /// Her places (newest first), then the studio's: what @ lists for her. Other models' places are left out.
    public static func forModel(_ modelId: String?, _ all: [SuiteLocation]) -> (hers: [SuiteLocation], studio: [SuiteLocation]) {
        let sorted = all.sorted { $0.createdAt > $1.createdAt }
        return (modelId == nil ? [] : sorted.filter { $0.modelId == modelId }, sorted.filter(\.isStudio))
    }

    /// The @ list's places for a query: hers first, then the studio's, matched on name or tag.
    public static func suggestions(_ modelId: String?, _ all: [SuiteLocation], query: String, limit: Int = 6) -> [SuiteLocation] {
        let q = query.lowercased()
        let (hers, studio) = forModel(modelId, all)
        let hit: (SuiteLocation) -> Bool = { q.isEmpty || $0.name.lowercased().contains(q) || $0.tag.contains(q) }
        return Array((hers.filter(hit) + studio.filter(hit)).prefix(limit))
    }

    /// The names on her page's "Her world" row ("Apartment, Rooftop, Café by the gym").
    public static func summary(_ places: [SuiteLocation]) -> String {
        places.isEmpty ? "None yet" : places.map(\.name).joined(separator: ", ")
    }

    public static func money(_ v: Double) -> String { String(format: "$%.2f", v) }
}
