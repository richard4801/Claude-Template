import Foundation

// AI suite (workstream 1): the video composer shell's pure rules (plans/video-composer.md): the tools as presets of one
// shell (their slots and chips), the slot cards a tool shows on a quality, the preset-collapsed composer, the Generate
// price states, the hardware wheels (Auto first, visible options only, merged ids shown as their survivor) and the
// bottom bar's ranges. No layout: the app's Views/Suite/Composer draws these.

// MARK: Tools

/// Shot, Character swap, Recast, Talking, UGC ad, Storyboard and Extend & upscale: one composer with a different tool card.
public enum ComposerTool: String, CaseIterable, Sendable, Identifiable {
    case shot, swap, recast, talking, ugc, storyboard, extend
    /// Stills of the character (workstream 3): Photoshoot on the shell (SuitePhoto.swift).
    case photo
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shot: return "Shot"
        case .swap: return "Character swap"
        case .recast: return "Recast"
        case .talking: return "Talking"
        case .ugc: return "UGC ad"
        case .storyboard: return "Storyboard"
        case .extend: return "Extend & upscale"
        case .photo: return "Photo"
        }
    }

    /// The tool card's one-liner.
    public var tagline: String {
        switch self {
        case .shot: return "Your character in a scene"
        case .swap: return "Put your character into a real clip"
        case .recast: return "Same take, new cast · up to 4 people"
        case .talking: return "Your character says your words"
        case .ugc: return "Your character with your product"
        case .storyboard: return "Scenes with one cast, one look"
        case .extend: return "Longer, smoother, sharper"
        case .photo: return "Stills of your character"
        }
    }

    /// The tool card's still (a bundled hardware render).
    public var render: String {
        switch self {
        case .shot: return "palette-04-bleached-warm"
        case .swap: return "palette-01-naturalistic"
        case .recast: return "palette-02-teal-orange"
        case .talking: return "light-06-ring-creator"
        case .ugc: return "grip-05-slider"
        case .storyboard: return "palette-05-sodium-decay"
        case .extend: return "stock-03-sensor"
        case .photo: return "light-04-window"
        }
    }

    /// No backend yet: the tool card shows a quiet "Coming soon" and no Generate. (Extend is live: suite/extend.ts.)
    public var comingSoon: Bool { self == .talking || self == .ugc }

    /// The tool's id in `catalog.tools` (UGC ad is "ugc_ad").
    public var wireId: String { self == .ugc ? "ugc_ad" : rawValue }

    /// "Coming soon" as the catalog's `tools` say (not available); a catalog without `tools`, or without this tool,
    /// keeps the app's own list (`comingSoon`).
    public func isComingSoon(in catalog: SuiteCatalog?) -> Bool {
        guard let t = catalog?.tools.first(where: { $0.id == wireId }) else { return comingSoon }
        return !t.available
    }

    /// The setting chips above the prompt (the spec's tools table).
    public var chips: [ComposerChip] {
        switch self {
        case .shot: return ComposerChip.allCases
        case .swap, .recast: return [.look]
        case .extend: return []
        case .talking: return [.camera, .look, .lighting]
        case .ugc: return [.style]
        case .storyboard: return [.style, .look]
        // Photo: no References chip (references are a slot), and Style has no tempo, Camera no movement.
        case .photo: return [.style, .camera, .look, .lighting]
        }
    }

    /// Slots the tool needs before it can generate.
    public var required: [ComposerSlot] {
        switch self {
        case .shot: return []
        case .swap: return [.clip, .character]
        case .recast: return [.clip, .people]
        case .talking: return [.character, .audio]
        case .ugc: return [.character, .product]
        case .storyboard: return [.scenes]
        case .extend: return [.video]
        case .photo: return [] // a character OR an image (owner 2026-11-11): SuitePhoto photoMissing
        }
    }

    public var optional: [ComposerSlot] {
        switch self {
        case .shot: return [.character, .startFrame, .endFrame]
        case .talking: return [.location]
        case .ugc: return [.referenceAd]
        case .photo: return [.character, .product, .references]
        default: return []
        }
    }

    /// Whether the prompt box shows (Swap keeps it behind a toggle, off by default).
    public var showsPrompt: Bool {
        switch self {
        case .shot, .talking, .ugc, .photo: return true
        default: return false
        }
    }

    public var promptPlaceholder: String {
        switch self {
        case .talking: return "What does she say? · type @ for your characters"
        case .ugc: return "Describe the ad · type @ for your characters, # for a camera move"
        case .swap: return "Anything to change? · type # for a camera move"
        case .photo: return "Describe the scene and what she does · type @ for your characters"
        default: return "Describe the scene · type @ for your characters, # for a camera move"
        }
    }

    /// The tools on the shell, in the browser's order.
    public static let shell: [ComposerTool] = [.shot, .photo, .swap, .recast, .talking, .ugc, .storyboard, .extend]

    /// Photo makes stills: no movement, tempo, length, sound, speaking, quality or shape.
    public var isStill: Bool { self == .photo }
}

/// A square slot card beside the prompt.
public enum ComposerSlot: String, CaseIterable, Sendable, Identifiable {
    case character, startFrame, endFrame, clip, people, audio, location, product, referenceAd, scenes, video
    /// Photo: up to 3 reference images, each guiding the pose, the look or the scene.
    case references
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .character: return "Character"
        case .startFrame: return "Start frame"
        case .endFrame: return "End frame"
        case .clip: return "Clip"
        case .people: return "People"
        case .audio: return "Audio"
        case .location: return "Location"
        case .product: return "Product"
        case .referenceAd: return "Reference ad"
        case .scenes: return "Scenes"
        case .video: return "Video"
        case .references: return "References"
        }
    }

    /// The caption under the label: what goes in and its limit.
    public var caption: String {
        switch self {
        case .character: return "Your models"
        case .startFrame: return "Sets the shape"
        case .endFrame: return "Where it lands"
        case .clip: return "Clip 3–30 s"
        case .people: return "1–4 people"
        case .audio: return "Record or upload"
        case .location: return "A photo of the place"
        case .product: return "A photo of it"
        case .referenceAd: return "An ad to follow"
        case .scenes: return "+ Add scene"
        case .video: return "The take to finish"
        case .references: return "Up to 3 · pose, look or scene"
        }
    }

    /// The input slot behind the card, when it is one of the shot's input slots.
    public var slotId: SlotId? {
        switch self {
        case .startFrame: return SlotId(.start)
        case .endFrame: return SlotId(.end)
        case .audio: return SlotId(.audio)
        case .product, .location: return SlotId(.image)
        case .referenceAd: return SlotId(.video)
        default: return nil
        }
    }
}

/// One slot card as the composer draws it.
public struct ComposerSlotCard: Hashable, Sendable, Identifiable {
    public var slot: ComposerSlot
    /// Shows the "Optional" pill.
    public var optional: Bool
    /// Greyed until its prerequisite exists (the end frame before a start frame).
    public var waiting: Bool
    public var caption: String
    public var id: String { slot.rawValue }

    public init(slot: ComposerSlot, optional: Bool, waiting: Bool = false, caption: String? = nil) {
        self.slot = slot
        self.optional = optional
        self.waiting = waiting
        self.caption = caption ?? slot.caption
    }
}

public enum ComposerSlots {
    /// The cards a tool shows on a quality: frame and audio slots only when the tier takes them; the end frame greyed
    /// ("After a start frame") until a start frame is in.
    public static func cards(_ tool: ComposerTool, inputs: SuiteInputs, slots: InputSlots = InputSlots()) -> [ComposerSlotCard] {
        let all = tool.required.map { ($0, false) } + tool.optional.map { ($0, true) }
        return all.compactMap { slot, optional -> ComposerSlotCard? in
            // Photo doesn't render on a video tier, so its PRODUCT slot never depends on what a tier takes.
            if let id = slot.slotId, id.kind.capacity(inputs) == 0, !tool.comingSoon, !tool.isStill { return nil }
            if let id = slot.slotId, slots.isWaiting(id) {
                return ComposerSlotCard(slot: slot, optional: optional, waiting: true, caption: slots.waitingCaption(id))
            }
            return ComposerSlotCard(slot: slot, optional: optional)
        }
    }

    /// The preset-collapsed composer (C6): only who (or the photo / clip that preset is about), the shape and Generate.
    public static func collapsed(preset: String?) -> [ComposerSlot] {
        switch preset {
        case "product_hero": return [.product]
        default: return [.character]
        }
    }

    /// "Up to 6 images" for the References chip and its popover.
    public static func referencesCaption(_ inputs: SuiteInputs) -> String {
        let n = SlotKind.image.capacity(inputs)
        return n == 0 ? "Not on this quality" : "Up to \(n) image\(n == 1 ? "" : "s")"
    }
}

// MARK: The price on Generate

/// What the Generate button says: "—" until the price is known, "Free" for test renders, else the estimate's own label.
/// A cap problem shows the estimate's `message` and Generate stays off.
public enum GeneratePrice: Equatable, Sendable {
    case unknown
    case free
    case price(String)
    case problem(String)

    public static func of(_ e: ShotEstimate?) -> GeneratePrice {
        guard let e else { return .unknown }
        if let p = e.problem { return .problem(p) }
        if e.test { return .free }
        return .price(e.buttonLabel)
    }

    public var buttonText: String {
        switch self {
        case .unknown, .problem: return "Generate · —"
        case .free: return "Generate · Free"
        case .price(let l): return l
        }
    }

    public var canGenerate: Bool {
        switch self {
        case .free, .price: return true
        case .unknown, .problem: return false
        }
    }

    public var problem: String? { if case .problem(let m) = self { return m } else { return nil } }
}

// MARK: Wheels

/// One item on a hardware drum (`RigDrum` on the Mac). `value` nil is Auto. `caption` is what you'll see, in plain
/// words (the option's `description`), never its spec line.
public struct WheelItem: Hashable, Sendable, Identifiable {
    public var value: String?
    public var name: String
    public var caption: String
    public var render: String?
    /// The card's rendered still in the bundled `previews/` folder (the Angle wheels), when the catalog has one.
    public var preview: String?
    public var id: String { value ?? "auto" }

    public init(value: String?, name: String, caption: String = "", render: String? = nil, preview: String? = nil) {
        self.preview = preview
        self.value = value
        self.name = name
        self.caption = caption
        self.render = render
    }

    public static func auto(_ caption: String = "The scene decides") -> WheelItem { WheelItem(value: nil, name: "Auto", caption: caption) }
}

public enum Wheel {
    /// One wheel step up (-1) or down (+1), stopping at the ends.
    public static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }

    /// "5 / 11" over a wheel.
    public static func position(_ index: Int, count: Int) -> String { "\(min(index, max(count - 1, 0)) + 1) / \(count)" }

    /// Where a picked id sits on a wheel; a merged id sits on its survivor, unknown ids and nil on Auto.
    public static func index(of id: String?, in items: [WheelItem], options: [SuiteOption] = []) -> Int {
        guard let id else { return 0 }
        let s = ComposerCatalog.survivor(options, id) ?? id
        return items.firstIndex { $0.value == s } ?? 0
    }
}

/// The wheels of the Camera picker (Setup and Angle): Auto first, then only the visible options.
public enum ComposerWheels {
    /// Auto's caption on the hardware drums.
    public static let autoCaption = "Picks for the shot"

    static func options(_ list: [SuiteOption], render: String? = nil, auto: String = "The scene decides") -> [WheelItem] {
        [.auto(auto)] + ComposerCatalog.visible(list).map { WheelItem(value: $0.id, name: $0.label, caption: $0.description, render: $0.render ?? render, preview: $0.preview?.poster) }
    }

    public static func cameras(_ c: CameraCatalog) -> [WheelItem] { options(c.bodies, auto: autoCaption) }
    public static func lenses(_ c: CameraCatalog) -> [WheelItem] { options(c.lenses, auto: autoCaption) }
    public static func heights(_ c: CameraCatalog) -> [WheelItem] { options(c.heights) }
    public static func framings(_ c: CameraCatalog) -> [WheelItem] { options(c.shotSizes) }

    /// "f/2.8" with what it does as the caption ("Subject pops, gentle blur"); the iris render rides along.
    public static func apertures(_ c: CameraCatalog) -> [WheelItem] {
        let iris = c.optic("aperture")?.render
        return [.auto(autoCaption)] + ComposerCatalog.visible(c.apertures).map {
            WheelItem(value: $0.id, name: $0.label, caption: apertureCaption($0.id), render: iris)
        }
    }

    /// "50 mm" with what it shows as the caption ("Like your eye sees"); the value is the focal length as text ("50").
    public static func focals(_ c: CameraCatalog) -> [WheelItem] {
        [.auto(autoCaption)] + ComposerCatalog.focalSteps(c).map { mm in
            WheelItem(value: focalText(mm), name: "\(focalText(mm)) mm", caption: focalCaption(mm))
        }
    }

    public static func focalText(_ mm: Double) -> String { mm == mm.rounded() ? String(Int(mm)) : String(mm) }

    public static func focalIndex(_ mm: Double?, in items: [WheelItem]) -> Int {
        guard let mm else { return 0 }
        return items.firstIndex { $0.value == focalText(mm) } ?? 0
    }

    public static func focalCaption(_ mm: Double) -> String {
        switch mm {
        case ..<20: return "Huge space, bent edges"
        case ..<30: return "Room and context"
        case ..<45: return "Everyday, a touch wide"
        case ..<70: return "Like your eye sees"
        case ..<110: return "Flattering, tighter faces"
        default: return "Compressed, far away"
        }
    }

    public static func apertureCaption(_ id: String) -> String {
        guard let f = Double(id.dropFirst()) else { return "" }
        switch f {
        case ..<2: return "Background melts away"
        case ..<4: return "Subject pops, gentle blur"
        case ..<8: return "Most of the scene sharp"
        default: return "Front to back in focus"
        }
    }

    /// The field of view, in degrees, a focal length shows on a full-frame camera (for the wheel's diagram).
    public static func fieldOfView(_ mm: Double) -> Double { 2 * atan(36.0 / (2 * max(mm, 1))) * 180 / .pi }
}

// MARK: Moves (Movement step)

public enum ComposerMoves {
    public static let featured = "featured"

    /// A Movement chip's moves: Featured is the library (in its order), others the moves of that group; a search looks
    /// through every move.
    public static func list(_ c: CameraCatalog, group: String, query: String = "") -> [SuiteMoveOption] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return PromptTokens.searchMoves(c, q) }
        if group == featured {
            let lib = c.library.compactMap { l in c.move(l.id) ?? SuiteMoveOption(id: l.id, label: l.label, description: l.description, category: l.category) }
            return lib.isEmpty ? c.moves : lib.map { m in c.libraryMove(m.id).map { var x = m; x.label = $0.label; return x } ?? m }
        }
        return c.moves.filter { $0.group == group }
    }

    /// The chips over the grid: the catalog's groups, or Featured alone on an older server.
    public static func groups(_ c: CameraCatalog) -> [SuiteMoveGroup] {
        c.moveGroups.isEmpty ? [SuiteMoveGroup(id: featured, label: "Featured")] : c.moveGroups
    }
}

/// A picker tile's preview: a still (a bundled render) now, a short muted loop later. Swapping the still for a loop is only
/// a data change: set `video`; the still stays the fallback.
public struct PickerPreview: Hashable, Sendable {
    /// A bundled hardware render (`hardware/<name>.webp`).
    public var still: String?
    /// A loop in the bundled `previews/` folder ("moves/dolly_in.mp4"), or a URL.
    public var video: String?
    /// The preview's own still in `previews/` ("moves/dolly_in.webp"): shown first, and the fallback; wins over `still`.
    public var poster: String?
    public init(still: String?, video: String? = nil, poster: String? = nil) {
        self.still = still
        self.video = video
        self.poster = poster
    }

    /// The tile has its own rendered preview (no drawn arrow needed).
    public var hasRender: Bool { poster != nil || video != nil }

    /// Moves without a preview share one neutral still (the same subject in every clip); the tile draws the move's arrow.
    public static let neutralMoveStill = "light-01-soft-cross"
    public static func move(_ m: SuiteMoveOption) -> PickerPreview {
        guard let p = m.preview, !p.poster.isEmpty || p.video != nil else { return PickerPreview(still: neutralMoveStill) }
        return PickerPreview(still: neutralMoveStill, video: p.video, poster: p.poster.isEmpty ? nil : p.poster)
    }
    public static func option(_ o: SuiteOption) -> PickerPreview {
        PickerPreview(still: o.render, video: o.preview?.video, poster: o.preview.flatMap { $0.poster.isEmpty ? nil : $0.poster })
    }
    /// An Auto tile with the catalog's preview (Lighting), else nil (the plain Auto art).
    public static func auto(_ p: SuitePreview?) -> PickerPreview? {
        guard let p, !p.poster.isEmpty else { return nil }
        return PickerPreview(still: nil, video: p.video, poster: p.poster)
    }

    /// Where a `previews/` path lives in the app bundle: its subdirectory, file name and extension
    /// ("moves/dolly_in.mp4" → previews/moves, dolly_in, mp4). nil for URLs and empty paths.
    public static func bundled(_ path: String?, defaultExtension: String = "jpg") -> (subdirectory: String, name: String, ext: String)? {
        guard var p = path?.trimmingCharacters(in: .whitespaces), !p.isEmpty, !p.contains("://"), !p.hasPrefix("file:") else { return nil }
        while p.hasPrefix("/") { p.removeFirst() }
        if p.hasPrefix("previews/") { p.removeFirst("previews/".count) }
        let ns = p as NSString
        let dir = ns.deletingLastPathComponent
        let file = ns.lastPathComponent as NSString
        let ext = file.pathExtension.isEmpty ? defaultExtension : file.pathExtension
        let name = file.deletingPathExtension
        guard !name.isEmpty else { return nil }
        return (dir.isEmpty ? "previews" : "previews/\(dir)", name, ext)
    }
}

// MARK: Bottom bar

/// The Speaking pill: Auto (the server decides), On, Off.
public enum ComposerSpeaking: String, CaseIterable, Sendable {
    case auto, on, off
    public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    public var value: Bool? {
        switch self {
        case .auto: return nil
        case .on: return true
        case .off: return false
        }
    }
}

public enum ComposerBar {
    /// The Length slider's range for a tier (the catalog's min/maxSeconds).
    public static func lengthRange(_ tier: SuiteTier?) -> ClosedRange<Int> {
        let lo = Int((tier?.minSeconds ?? 4).rounded())
        let hi = Int((tier?.maxSeconds ?? 15).rounded())
        return max(1, lo)...max(max(1, lo), hi)
    }

    public static func clampLength(_ s: Int, _ tier: SuiteTier?) -> Int {
        let r = lengthRange(tier)
        return min(max(s, r.lowerBound), r.upperBound)
    }

    public static func takes(_ catalogMax: Int) -> [Int] { Array(1...min(max(catalogMax, 1), 4)) }

    /// The collapsed composer's shape tiles.
    public static let shapes = ["9:16", "1:1", "16:9"]

    /// What a quality takes, for its card in the Quality pill ("Start + end frame · refs · clips").
    public static func acceptsLine(_ i: SuiteInputs) -> String {
        var parts: [String] = []
        if i.start && i.end && i.middle > 0 {
            parts.append("Start, middle, end")
        } else if i.start && i.end {
            parts.append("Start + end frame")
        } else if i.start {
            parts.append("Start frame")
        }
        if i.images > 0 { parts.append("refs") }
        if i.videos > 0 { parts.append("clips") }
        if i.audio { parts.append("audio") }
        return parts.isEmpty ? "Prompt only" : parts.joined(separator: " · ")
    }
}

// MARK: Presets (the beginner path)

public enum ComposerPresets {
    /// The tile's still: the preset's palette, light, body or lens render.
    public static func render(_ p: SuitePreset, _ c: CameraCatalog) -> String? {
        let r = { (list: [SuiteOption], id: String?) -> String? in id.flatMap { i in list.first { $0.id == i }?.render } }
        return r(c.palettes, p.spec.palette?.preset) ?? r(c.lighting, p.spec.lighting?.preset) ?? r(c.bodies, p.spec.rig?.body) ?? r(c.lenses, p.spec.rig?.lens)
    }

    /// "Draft · 8 s · film look, slow push" over the collapsed composer's Generate.
    public static func summary(_ p: SuitePreset?, quality: String, seconds: Int) -> String {
        let d = p?.description ?? ""
        let line = d.isEmpty ? "" : " · " + d.prefix(1).lowercased() + d.dropFirst()
        return "\(SuiteText.tierLabel(quality)) · \(seconds) s\(line)"
    }
}

// MARK: The composer's draft

/// Everything a composer has set. A value type, so a change re-prices it.
public struct ComposerDraft: Hashable, Sendable {
    public var tool: ComposerTool
    public var tokens: PromptTokens
    public var settings: ComposerSettings
    /// The character's outfit (picked inside the CHARACTER slot).
    public var outfitId: String?
    public var quality: String
    public var aspect: String
    public var duration: Int
    public var sound: Bool
    public var speaking: ComposerSpeaking
    public var takes: Int
    /// C6: the preset the composer is collapsed to (nil = the full composer).
    public var collapsed: String?
    /// Owner: the camera from Directed mode (it replaces the chips' camera).
    public var directed: CameraSpec?
    /// Owner: the engine pinned for this shot (one of the tier's `models`), nil = Auto (the ladder). Members never set it.
    public var engineModel: String?
    public var resolution: String?
    /// Extend: the video, After / Before and what happens (ComposerExtend.swift).
    public var extend: ExtendDraft
    /// Images sent (server images/sent.ts): Claude's or the person's choice of the images the model gets, as the draft's
    /// `sent` ({sentImages | addImages, excludeImages, sentImagesBy}). nil = automatic; `.null` = reset to automatic (the
    /// server then drops a choice it kept).
    public var sent: JSONValue? = nil

    public init(tool: ComposerTool = .shot, tokens: PromptTokens = PromptTokens(), settings: ComposerSettings = ComposerSettings(), outfitId: String? = nil,
                quality: String = "draft", aspect: String = "9:16", duration: Int = 8, sound: Bool = true, speaking: ComposerSpeaking = .auto, takes: Int = 1,
                collapsed: String? = nil, directed: CameraSpec? = nil, engineModel: String? = nil, resolution: String? = nil, extend: ExtendDraft = ExtendDraft()) {
        self.extend = extend
        self.engineModel = engineModel
        self.resolution = resolution
        self.tool = tool
        self.tokens = tokens
        self.settings = settings
        self.outfitId = outfitId
        self.quality = quality
        self.aspect = aspect
        self.duration = duration
        self.sound = sound
        self.speaking = speaking
        self.takes = takes
        self.collapsed = collapsed
        self.directed = directed
    }

    /// A short title from the prompt ("Noor walks into a…"), else the tool's name.
    public var title: String {
        let words = tokens.promptText().split(separator: " ").prefix(5).joined(separator: " ")
        return words.isEmpty ? tool.title : words
    }

    /// The shot request: the prompt and chips, the bottom bar, the input slots this tier takes, then the @locations
    /// (as location references, while the References limit has room) and the owner's pinned engine.
    public func request(_ slots: InputSlots, _ inputs: SuiteInputs, locations: [SuiteLocation] = []) -> ShotRequest {
        var s = settings
        if tool != .ugc { s.format = nil }
        var r = composerRequest(tokens, s, quality: quality, aspectRatio: aspect, duration: duration, takes: takes, speaking: speaking.value, title: title)
        r.audio = sound
        if r.modelId != nil, r.outfitId == nil { r.outfitId = outfitId }
        if let d = directed { r.camera = d }
        r = slots.apply(to: r, inputs)
        let images = r.references?.images
        let roled = { (role: String) -> [SuiteRefImage]? in images?.map { x -> SuiteRefImage in var i = x; i.role = role; return i } }
        switch tool {
        case .talking:
            // Talking: she says the AUDIO slot's words (speaking on unless switched off); the optional image is where.
            if r.speaking == nil { r.speaking = true }
            if r.references != nil { r.references!.images = roled("location") }
        case .ugc:
            // UGC ad: the PRODUCT slot is the product; the optional reference ad rides in references.videos.
            if r.references != nil { r.references!.images = roled("product") }
        default: break
        }
        r = ComposerLocations.apply(r, tokens: tokens, locations: locations, inputs: inputs)
        if let e = engineModel {
            r.engineModel = e
            r.resolution = resolution
        }
        return r
    }

    /// What the tool still needs before Generate (its required slots), as a line to show; nil when it can go.
    public func missing(_ slots: InputSlots) -> String? {
        let ready = { (id: SlotId) -> Bool in slots[id]?.ready ?? false }
        for s in tool.required {
            switch s {
            case .character where tokens.characterId == nil: return "Pick a character first"
            case .audio where !ready(SlotId(.audio)): return "Add the audio she says"
            case .product where !ready(SlotId(.image)): return "Add a photo of the product"
            case .video where extend.source == nil: return "Pick a take or upload a video to extend"
            default: continue
            }
        }
        return nil
    }

    /// What this shot's inputs follow: the pinned engine's (`tier.slots(for:)`), else the tier's.
    public func inputs(_ catalog: SuiteCatalog?) -> SuiteInputs {
        catalog?.tier(quality)?.slots(for: engineModel) ?? .none
    }

    /// The prompt was backspaced to empty (owner decision 2026-11-08): the selected preset is let go and the composer is the
    /// normal one again, its rows back on Auto (the grade switch stays). Nothing changes while the prompt has anything in it
    /// or no preset is selected.
    public func unselectingPreset() -> ComposerDraft {
        guard tokens.isEmpty, collapsed != nil || settings.preset != nil else { return self }
        var d = self
        d.collapsed = nil
        d.directed = nil
        d.settings = ComposerSettings(gradeLook: settings.gradeLook)
        return d
    }

    /// Picking a preset: its values go in the chips, its move becomes a #move, and the composer collapses (C6).
    public func applying(preset p: SuitePreset, _ c: CameraCatalog) -> ComposerDraft {
        var d = self
        d.settings = ComposerSettings.fromPreset(c, p.id, gradeLook: settings.gradeLook)
        var t = PromptTokens(tokens.parts.filter { $0.move == nil })
        if let m = p.spec.move, let opt = c.move(m.id) {
            t = t.addMove(opt, intensity: Int(((m.intensity ?? 0.5) * 100).rounded()), catalog: c).0
        }
        d.tokens = t
        d.collapsed = p.id
        d.directed = nil
        return d
    }
}

// MARK: Typing a token

extension PromptTokens {
    /// Picking a suggestion: the `@…` / `#…` being typed in text part `part` (from `trigger.start` to `caret`) is taken out,
    /// and the caret where the token goes is returned.
    public func removingTrigger(_ trigger: PromptTrigger, part: Int, caret: Int) -> (PromptTokens, Caret) {
        guard parts.indices.contains(part), let t = parts[part].text else { return (self, caretAtEnd) }
        let chars = Array(t)
        let s = min(max(trigger.start, 0), chars.count)
        let e = min(max(caret, s), chars.count)
        let rest = String(chars[0..<s]) + String(chars[e...])
        return (setText(part: part, rest), Caret(part, s))
    }

    /// A token's place in the parts, by key.
    public func index(ofKey key: Int) -> Int? { parts.firstIndex { $0.key == key } }

    /// The newest token's key.
    public var lastKey: Int? { parts.compactMap(\.key).max() }
}

// MARK: The rig check (workstream 3, plans/video-composer.md "Rig check")

extension JSONValue {
    /// JSON Merge Patch (RFC 7386): objects merge key by key, null removes a key, anything else replaces.
    public func mergePatched(_ patch: JSONValue) -> JSONValue {
        guard case .object(let p) = patch else { return patch }
        var out: [String: JSONValue] = [:]
        if case .object(let o) = self { out = o }
        for (k, v) in p {
            if case .null = v { out.removeValue(forKey: k) } else { out[k] = (out[k] ?? .null).mergePatched(v) }
        }
        return .object(out)
    }

    /// A Codable value as JSON (nil when it can't be encoded).
    static func encoding<T: Encodable>(_ v: T) -> JSONValue? {
        guard let d = try? JSONEncoder().encode(v) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: d)
    }

    /// This JSON as a Codable value (nil when it doesn't fit).
    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let d = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

/// A rig fix's merge patch applied to the composer's choices, the way a tap in the picker would set them: rig, angle,
/// look, lighting and style values go into the chips (null = Auto), `move` / `mix` become the prompt's #move chips (first
/// = move, second = mix; `mix: null` takes the second chip out). Owner's Directed camera: the patch merges into it.
public enum RigFixes {
    public static func apply(_ patch: JSONValue, to draft: ComposerDraft, catalog: CameraCatalog) -> ComposerDraft {
        guard case .object(let top) = patch else { return draft }
        var d = draft
        for (k, v) in top {
            switch k {
            case "camera": d = camera(v, d, catalog)
            case "speaking":
                if case .null = v { d.speaking = .auto } else if case .bool(let b) = v { d.speaking = b ? .on : .off }
            case "audio": if case .bool(let b) = v { d.sound = b }
            case "aspectRatio": if case .string(let s) = v { d.aspect = s }
            case "duration": if case .number(let n) = v { d.duration = Int(n.rounded()) }
            case "takes": if case .number(let n) = v { d.takes = min(max(Int(n.rounded()), 1), 4) }
            default: continue
            }
        }
        return d
    }

    private static func camera(_ v: JSONValue, _ draft: ComposerDraft, _ cat: CameraCatalog) -> ComposerDraft {
        var d = draft
        if let directed = d.directed {
            d.directed = (JSONValue.encoding(directed) ?? .null).mergePatched(v).decoded(CameraSpec.self)
            return d
        }
        var s = d.settings
        guard case .object(let c) = v else {
            if case .null = v {
                s = s.reset(.camera).reset(.look).reset(.lighting).reset(.style)
                s.gradeLook = d.settings.gradeLook
                d.settings = s
                d.tokens = d.tokens.settingMoves([], catalog: cat)
            }
            return d
        }
        for (k, x) in c {
            switch k {
            case "rig":
                if case .null = x { s.body = nil; s.lens = nil; s.focalMm = nil; s.aperture = nil; s.stock = nil }
                for (f, y) in fields(x) {
                    switch f {
                    case "body": set(&s.body, y)
                    case "lens": set(&s.lens, y)
                    case "aperture": set(&s.aperture, y)
                    case "look": set(&s.stock, y)
                    case "focalMm": set(&s.focalMm, y)
                    default: continue
                    }
                }
            case "angle":
                if case .null = x { s.height = nil; s.shotSize = nil }
                for (f, y) in fields(x) {
                    if f == "height" { set(&s.height, y) } else if f == "shotSize" { set(&s.shotSize, y) }
                }
            case "palette":
                if case .null = x { s.palette = nil }
                if let y = fields(x)["preset"] { set(&s.palette, y) }
            case "lighting":
                if case .null = x { s.lighting = nil }
                if let y = fields(x)["preset"] { set(&s.lighting, y) }
            case "style":
                if case .null = x { s.genre = nil; s.era = nil; s.tempo = nil; s.format = nil }
                for (f, y) in fields(x) {
                    switch f {
                    case "genre": set(&s.genre, y)
                    case "era": set(&s.era, y)
                    case "tempo": set(&s.tempo, y)
                    case "format": set(&s.format, y)
                    default: continue
                    }
                }
            case "preset": set(&s.preset, x)
            default: continue
            }
        }
        d.settings = s
        if c["move"] != nil || c["mix"] != nil {
            let cur = d.tokens.moves.compactMap(\.move)
            let merged = { (key: String, old: SuiteMove?) -> SuiteMove? in
                guard let p = c[key] else { return old }
                if case .null = p { return nil }
                return (old.flatMap { JSONValue.encoding($0) } ?? .null).mergePatched(p).decoded(SuiteMove.self)
            }
            var want: [SuiteMove] = []
            for m in [merged("move", cur.first), merged("mix", cur.count > 1 ? cur[1] : nil)] {
                if let m, !want.contains(where: { $0.id == m.id }) { want.append(m) }
            }
            d.tokens = d.tokens.settingMoves(want, catalog: cat)
        }
        return d
    }

    private static func fields(_ v: JSONValue) -> [String: JSONValue] {
        if case .object(let o) = v { return o }
        return [:]
    }

    private static func set(_ field: inout String?, _ v: JSONValue) {
        switch v {
        case .null: field = nil
        case .string(let s): field = s
        default: break
        }
    }

    private static func set(_ field: inout Double?, _ v: JSONValue) {
        switch v {
        case .null: field = nil
        case .number(let n): field = n
        default: break
        }
    }
}

extension ComposerDraft {
    /// The draft with a rig fix (or alt) applied.
    public func applying(_ fix: RigFix, catalog: CameraCatalog) -> ComposerDraft { RigFixes.apply(fix.patch, to: self, catalog: catalog) }
}

extension PromptTokens {
    /// The #move chips set to `want` (first = move, second = mix). A chip that stays keeps its place, key and label; a
    /// changed move takes the place of the chip it replaces; a chip no longer wanted goes; a new one goes at the end.
    /// Unlike a picker tap this never refuses: the server drops a pair it can't mix (and says so in the estimate).
    public func settingMoves(_ want: [SuiteMove], catalog: CameraCatalog) -> PromptTokens {
        let percent = { (m: SuiteMove, fallback: Int) -> Int in m.intensity.map { min(max(Int(($0 * 100).rounded()), 0), 100) } ?? fallback }
        let token = { (m: SuiteMove, key: Int, fallback: Int) -> PromptPart in
            let o = catalog.move(m.id)
            return .move(id: m.id, label: o?.label ?? m.id, category: o?.category ?? "", intensity: percent(m, fallback), key: key)
        }
        var parts = self.parts
        var pending = want.filter { w in !parts.contains { $0.moveInfo?.id == w.id } }
        var drop: [Int] = []
        for i in parts.indices {
            guard let info = parts[i].moveInfo, let key = parts[i].key else { continue }
            if let w = want.first(where: { $0.id == info.id }) {
                parts[i] = .move(id: info.id, label: info.label, category: info.category, intensity: percent(w, info.intensity), key: key)
            } else if !pending.isEmpty {
                parts[i] = token(pending.removeFirst(), key, info.intensity)
            } else {
                drop.append(key)
            }
        }
        var out = PromptTokens(parts)
        for k in drop { out = out.remove(key: k) }
        var next = (out.parts.compactMap(\.key).max() ?? 0) + 1
        for w in pending {
            out.parts.append(token(w, next, 50))
            next += 1
        }
        // The order says which is the move and which the mix.
        let at = out.parts.indices.filter { out.parts[$0].moveInfo != nil }
        let ids = at.compactMap { out.parts[$0].moveInfo?.id }
        if ids.count == want.count, ids != want.map(\.id) {
            let byId = Dictionary(at.map { (out.parts[$0].moveInfo!.id, out.parts[$0]) }, uniquingKeysWith: { a, _ in a })
            for (n, i) in at.enumerated() { if let p = byId[want[n].id] { out.parts[i] = p } }
        }
        return out
    }
}

/// What the rig check reads from the composer's choices: the camera (chips, #moves or Directed) and the Speaking switch.
public struct RigChoices: Hashable, Sendable {
    public var camera: CameraSpec?
    public var speaking: Bool?
    public init(camera: CameraSpec? = nil, speaking: Bool? = nil) {
        self.camera = camera
        self.speaking = speaking
    }
    public init(_ r: ShotRequest) { self.init(camera: r.camera, speaking: r.speaking) }
}

/// The × on a rig warning: it stays hidden until the choices change. Typing in the prompt isn't a change of choices, but
/// a warning whose line changes (the prompt now says something else) shows again.
public struct RigDismissals: Hashable, Sendable {
    public private(set) var choices: RigChoices?
    /// Rule id → the reason line that was dismissed.
    public private(set) var hidden: [String: String] = [:]

    public init() {}

    /// The choices now: a change forgets every dismissal.
    public mutating func sync(_ c: RigChoices) {
        if c != choices {
            choices = c
            hidden = [:]
        }
    }

    public mutating func dismiss(_ w: RigWarning, at c: RigChoices) {
        sync(c)
        hidden[w.id] = w.reason
    }

    /// The warnings to show for these choices.
    public func visible(_ list: [RigWarning], at c: RigChoices) -> [RigWarning] {
        guard c == choices, !hidden.isEmpty else { return list }
        return list.filter { hidden[$0.id] != $0.reason }
    }
}
