import Foundation

// AI suite (workstream 1): the Shot's input slots (start / middle / end frames, reference images and videos, one audio
// track), pure so the rules are unit-tested. Which slots show comes from the catalog's `inputs` for the chosen tier (or,
// for the owner, the chosen engine): a slot shows only when that tier takes it. No layout here: a view asks for
// `InputSlots.visible(_:)` and arranges the tiles (InputSlotTile in the app) itself. Same rules as Android's InputSlots.kt.

/// What a tier (or one engine) takes. Counts are capped to what a shot request can carry. `framesWithRefs` false: with a
/// start or end frame, references are not sent on this quality.
public struct SuiteInputs: Codable, Hashable, Sendable {
    public var start: Bool
    public var end: Bool
    public var middle: Int
    public var images: Int
    public var videos: Int
    public var audio: Bool
    public var framesWithRefs: Bool

    public init(start: Bool = false, end: Bool = false, middle: Int = 0, images: Int = 0, videos: Int = 0, audio: Bool = false, framesWithRefs: Bool = false) {
        self.start = start
        self.end = end
        self.middle = middle
        self.images = images
        self.videos = videos
        self.audio = audio
        self.framesWithRefs = framesWithRefs
    }

    enum CodingKeys: String, CodingKey { case start, end, middle, images, videos, audio, framesWithRefs }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = c.v(.start, false)
        end = c.v(.end, false)
        middle = c.v(.middle, 0)
        images = c.v(.images, 0)
        videos = c.v(.videos, 0)
        audio = c.v(.audio, false)
        framesWithRefs = c.v(.framesWithRefs, false)
    }

    public static let none = SuiteInputs()

    /// A server from before `inputs`: keyframes = start + end, references = images and videos.
    public static func legacy(canKeyframes: Bool, canReferences: Bool) -> SuiteInputs {
        SuiteInputs(start: canKeyframes, end: canKeyframes, images: canReferences ? 6 : 0, videos: canReferences ? 3 : 0, framesWithRefs: canKeyframes && canReferences)
    }
}

extension SuiteTier {
    /// The input slots this tier takes (`inputs`, or worked out from the older flags).
    public var slots: SuiteInputs { inputs ?? .legacy(canKeyframes: canKeyframes, canReferences: canReferences) }
    /// Owner: what one engine of this tier takes (falls back to the tier's).
    public func slots(for engineModel: String?) -> SuiteInputs {
        guard let id = engineModel, let i = models?.first(where: { $0.model == id })?.inputs else { return slots }
        return i
    }
}

/// The kinds of slot, in the order a view usually lists them. `contentTypes` is what the file picker asks for.
public enum SlotKind: String, CaseIterable, Hashable, Sendable {
    case start, middle, end, image, video, audio

    public var label: String {
        switch self {
        case .start: return "Start frame"
        case .middle: return "Middle frame"
        case .end: return "End frame"
        case .image: return "Reference"
        case .video: return "Video"
        case .audio: return "Audio"
        }
    }

    public var hint: String {
        switch self {
        case .start: return "The shot opens on this"
        case .middle: return "A moment the shot passes through"
        case .end: return "The shot ends on this"
        case .image: return "A product, place, style or prop"
        case .video: return "Motion or camera to follow"
        case .audio: return "A voice or a beat"
        }
    }

    public var isImage: Bool { self == .start || self == .middle || self == .end || self == .image }
    public var isFrame: Bool { self == .start || self == .middle || self == .end }
    var isMany: Bool { self == .middle || self == .image || self == .video }

    /// The kind that must be filled before this one can be (the end frame needs a start frame), or nil.
    public var prerequisite: SlotKind? { self == .end ? .start : nil }

    /// How many of this kind the tier takes.
    public func capacity(_ i: SuiteInputs) -> Int {
        switch self {
        case .start: return i.start ? 1 : 0
        case .end: return i.end ? 1 : 0
        case .middle: return min(max(i.middle, 0), 8)
        case .image: return min(max(i.images, 0), 6)
        case .video: return min(max(i.videos, 0), 3)
        case .audio: return i.audio ? 1 : 0
        }
    }
}

/// One slot: its kind and its place among slots of the same kind (0-based).
public struct SlotId: Hashable, Sendable {
    public var kind: SlotKind
    public var index: Int
    public init(_ kind: SlotKind, _ index: Int = 0) {
        self.kind = kind
        self.index = index
    }
    /// "Reference 2", "Start frame".
    public var title: String { kind.isMany ? "\(kind.label) \(index + 1)" : kind.label }
}

/// What is in a slot: the picked file's name and, once uploaded, its image or media ref. `progress` is 0…1 while it
/// uploads; `error` is a member-safe line when it failed. `preview` is a local file URL string to draw before the upload
/// ends. References: `role` product | location | style | prop | person; video `use` motion | camera | style.
public struct SlotValue: Hashable, Sendable {
    public var name: String
    public var image: ImageRef?
    public var media: SuiteVideoRef?
    public var preview: String?
    public var progress: Double?
    public var error: String?
    public var role: String
    public var use: String
    /// Identifies one pick across renumbering (an upload finishing after the slots above it were cleared).
    public var token: UUID

    public init(name: String = "", image: ImageRef? = nil, media: SuiteVideoRef? = nil, preview: String? = nil, progress: Double? = nil, error: String? = nil,
                role: String = "product", use: String = "motion", token: UUID = UUID()) {
        self.name = name
        self.image = image
        self.media = media
        self.preview = preview
        self.progress = progress
        self.error = error
        self.role = role
        self.use = use
        self.token = token
    }

    public var ready: Bool { (image != nil || media != nil) && progress == nil && error == nil }
    public var uploading: Bool { progress != nil }
}

/// The filled slots of a shot. A value type: each change returns a new one.
public struct InputSlots: Hashable, Sendable {
    public var values: [SlotId: SlotValue]
    public init(_ values: [SlotId: SlotValue] = [:]) { self.values = values }

    public subscript(_ id: SlotId) -> SlotValue? { values[id] }

    private func filled(_ kind: SlotKind) -> [SlotId] { values.keys.filter { $0.kind == kind }.sorted { $0.index < $1.index } }

    /// The slots to show, in `SlotKind` order: for one-of kinds the single slot; for many-of kinds the filled ones the tier
    /// takes, then one empty "add" slot while there is room. Kinds the tier doesn't take don't show.
    public func visible(_ inputs: SuiteInputs) -> [SlotId] {
        SlotKind.allCases.flatMap { k -> [SlotId] in
            let cap = k.capacity(inputs)
            if cap == 0 { return [] }
            if cap == 1 && !k.isMany { return [SlotId(k)] }
            let have = filled(k).filter { $0.index < cap }
            return have.count < cap ? have + [SlotId(k, have.count)] : have
        }
    }

    /// Filled slots this tier doesn't take: they stay (switching back brings them back) but aren't sent.
    public func hidden(_ inputs: SuiteInputs) -> [SlotId] {
        values.keys.filter { $0.index >= $0.kind.capacity(inputs) }.sorted {
            let a = SlotKind.allCases.firstIndex(of: $0.kind)!, b = SlotKind.allCases.firstIndex(of: $1.kind)!
            return a != b ? a < b : $0.index < $1.index
        }
    }

    /// Where `put` stores a value for `id`: itself when filled, else the first free place of its kind.
    public func place(_ id: SlotId) -> SlotId { values[id] != nil ? id : SlotId(id.kind, min(id.index, filled(id.kind).count)) }

    public func put(_ id: SlotId, _ v: SlotValue) -> InputSlots {
        var n = values
        n[place(id)] = v
        return InputSlots(n)
    }

    /// Changes the value picked with `token`, wherever it has moved. Does nothing if it was cleared meanwhile.
    public func update(token: UUID, _ f: (SlotValue) -> SlotValue) -> InputSlots {
        guard let e = values.first(where: { $0.value.token == token }) else { return self }
        var n = values
        n[e.key] = f(e.value)
        return InputSlots(n)
    }

    /// Empties a slot; the others of its kind move up so there are no gaps.
    public func clear(_ id: SlotId) -> InputSlots {
        guard values[id] != nil else { return self }
        var rest = values
        rest[id] = nil
        var n = rest.filter { $0.key.kind != id.kind }
        for (i, e) in rest.filter({ $0.key.kind == id.kind }).sorted(by: { $0.key.index < $1.key.index }).enumerated() { n[SlotId(id.kind, i)] = e.value }
        return InputSlots(n)
    }

    /// A dependent slot whose prerequisite is still empty (an end frame before a start frame): shown greyed, not pickable.
    public func isWaiting(_ id: SlotId) -> Bool {
        guard let pre = id.kind.prerequisite else { return false }
        return filled(pre).isEmpty
    }

    /// Why a waiting slot is greyed ("After a start frame"), or nil when it can be filled.
    public func waitingCaption(_ id: SlotId) -> String? {
        guard isWaiting(id), let pre = id.kind.prerequisite else { return nil }
        return "After a \(pre.label.lowercased())"
    }

    public var uploading: Bool { values.values.contains { $0.uploading } }
    public var isEmpty: Bool { values.isEmpty }

    /// Ready values the tier takes, in order.
    private func sent(_ kind: SlotKind, _ inputs: SuiteInputs) -> [SlotValue] {
        filled(kind).filter { $0.index < kind.capacity(inputs) }.compactMap { values[$0] }.filter { $0.ready }
    }
    private func hasFrames(_ i: SuiteInputs) -> Bool { [.start, .middle, .end].contains { !sent($0, i).isEmpty } }
    private func hasRefs(_ i: SuiteInputs) -> Bool { [.image, .video, .audio].contains { !sent($0, i).isEmpty } }

    /// A line to show near the slots, or nil: frames and references both filled where this quality can't combine them,
    /// or filled slots this quality doesn't take.
    public func note(_ inputs: SuiteInputs) -> String? {
        if hasFrames(inputs) && hasRefs(inputs) && !inputs.framesWithRefs { return "On this quality the frames carry the look · references aren't used" }
        let h = hidden(inputs)
        if !h.isEmpty { return "\(h.count) input\(h.count > 1 ? "s" : "") not used on this quality" }
        return nil
    }

    /// `req` with the frames and references of the ready slots this tier takes (others left out, as the server would refuse them).
    public func apply(to req: ShotRequest, _ inputs: SuiteInputs) -> ShotRequest {
        var r = req
        let start = sent(.start, inputs).first?.image
        // The end frame rides only with a start frame (it is greyed until one exists).
        let end = start == nil ? nil : sent(.end, inputs).first?.image
        let middle = sent(.middle, inputs).compactMap { $0.image }
        r.frames = (start != nil || end != nil || !middle.isEmpty) ? SuiteFrames(start: start, middle: middle.isEmpty ? nil : middle, end: end) : nil
        let images = sent(.image, inputs).compactMap { v -> SuiteRefImage? in
            guard let i = v.image else { return nil }
            let base = (v.name as NSString).deletingPathExtension
            return SuiteRefImage(image: i, role: v.role, label: base.isEmpty ? nil : String(base.prefix(80)))
        }
        let videos = sent(.video, inputs).compactMap { v in v.media.map { SuiteRefVideo(video: $0, use: v.use) } }
        let audio = sent(.audio, inputs).first?.media.map { SuiteRefAudio(audio: $0) }
        r.references = (!images.isEmpty || !videos.isEmpty || audio != nil) ? SuiteReferences(images: images.isEmpty ? nil : images, videos: videos.isEmpty ? nil : videos, audio: audio) : nil
        return r
    }

    /// Image roles a reference can have, as the server names them.
    public static let roles = ["product", "location", "style", "prop", "person", "pose", "outfit"]
    /// What a reference video is for.
    public static let uses = ["motion", "camera", "style"]
    public static let maxImageBytes = 20 * 1024 * 1024
    public static let maxMediaBytes = 200 * 1024 * 1024
}
