import Foundation

// AI suite (workstream 1): the video composer shell's pure rules (plans/video-composer.md): the tools as presets of one
// shell (their slots and chips), the slot cards a tool shows on a quality, the preset-collapsed composer, the Generate
// price states, the hardware wheels (Auto first, visible options only, merged ids shown as their survivor) and the
// bottom bar's ranges. No layout: the app's Views/Suite/Composer draws these.

// MARK: Tools

/// Shot, Character swap, Recast, Talking, UGC ad, Storyboard and Extend & upscale: one composer with a different tool card.
public enum ComposerTool: String, CaseIterable, Sendable, Identifiable {
    case shot, swap, recast, talking, ugc, storyboard, extend
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
        }
    }

    /// No backend yet: the tool card shows a quiet "Coming soon" and no Generate.
    public var comingSoon: Bool { self == .talking || self == .ugc || self == .extend }

    /// The setting chips above the prompt (the spec's tools table).
    public var chips: [ComposerChip] {
        switch self {
        case .shot: return ComposerChip.allCases
        case .swap: return [.look]
        case .recast, .extend: return []
        case .talking: return [.camera, .look, .lighting]
        case .ugc: return [.style]
        case .storyboard: return [.style, .look]
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
        }
    }

    public var optional: [ComposerSlot] {
        switch self {
        case .shot: return [.character, .startFrame, .endFrame]
        case .talking: return [.location]
        case .ugc: return [.referenceAd]
        default: return []
        }
    }

    /// Whether the prompt box shows (Swap keeps it behind a toggle, off by default).
    public var showsPrompt: Bool {
        switch self {
        case .shot, .talking, .ugc: return true
        default: return false
        }
    }

    public var promptPlaceholder: String {
        switch self {
        case .talking: return "What does she say? · type @ for your characters"
        case .ugc: return "Describe the ad · type @ for your characters, # for a camera move"
        case .swap: return "Anything to change? · type # for a camera move"
        default: return "Describe the scene · type @ for your characters, # for a camera move"
        }
    }

    /// The tools on the shell, in the browser's order.
    public static let shell: [ComposerTool] = [.shot, .swap, .recast, .talking, .ugc, .storyboard, .extend]
}

/// A square slot card beside the prompt.
public enum ComposerSlot: String, CaseIterable, Sendable, Identifiable {
    case character, startFrame, endFrame, clip, people, audio, location, product, referenceAd, scenes, video
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
        }
    }

    /// The input slot behind the card, when it is one of the shot's input slots.
    public var slotId: SlotId? {
        switch self {
        case .startFrame: return SlotId(.start)
        case .endFrame: return SlotId(.end)
        case .audio: return SlotId(.audio)
        case .product: return SlotId(.image)
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
            if let id = slot.slotId, id.kind.capacity(inputs) == 0, !tool.comingSoon { return nil }
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

/// One card on a hardware wheel. `id` nil is Auto.
public struct WheelItem: Hashable, Sendable, Identifiable {
    public var value: String?
    public var name: String
    public var caption: String
    public var render: String?
    public var id: String { value ?? "auto" }

    public init(value: String?, name: String, caption: String = "", render: String? = nil) {
        self.value = value
        self.name = name
        self.caption = caption
        self.render = render
    }

    public static func auto(_ caption: String = "The scene decides") -> WheelItem { WheelItem(value: nil, name: "Auto", caption: caption) }
}

/// A wheel's three visible cards: previous, selected (centred) and next.
public struct WheelWindow<T: Hashable>: Hashable {
    public var previous: T?
    public var selected: T
    public var next: T?
}

public enum Wheel {
    /// The three cards around `selected` (clamped into the list); nil when the list is empty.
    public static func window<T: Hashable>(_ items: [T], selected: Int) -> WheelWindow<T>? {
        guard !items.isEmpty else { return nil }
        let i = min(max(selected, 0), items.count - 1)
        return WheelWindow(previous: i > 0 ? items[i - 1] : nil, selected: items[i], next: i + 1 < items.count ? items[i + 1] : nil)
    }

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
    static func options(_ list: [SuiteOption], render: String? = nil) -> [WheelItem] {
        [.auto()] + ComposerCatalog.visible(list).map { WheelItem(value: $0.id, name: $0.label, caption: $0.description, render: $0.render ?? render) }
    }

    public static func cameras(_ c: CameraCatalog) -> [WheelItem] { options(c.bodies) }
    public static func lenses(_ c: CameraCatalog) -> [WheelItem] { options(c.lenses) }
    public static func heights(_ c: CameraCatalog) -> [WheelItem] { options(c.heights) }
    public static func framings(_ c: CameraCatalog) -> [WheelItem] { options(c.shotSizes) }

    /// "f/1.4 · Dreamy blur" cards on the iris render.
    public static func apertures(_ c: CameraCatalog) -> [WheelItem] {
        let iris = c.optic("aperture")?.render
        return [.auto()] + ComposerCatalog.visible(c.apertures).map {
            WheelItem(value: $0.id, name: $0.description.isEmpty ? $0.label : "\($0.label) · \($0.description)", caption: apertureCaption($0.id), render: iris)
        }
    }

    /// "50 mm · Natural"; the value is the focal length in mm as text ("50").
    public static func focals(_ c: CameraCatalog) -> [WheelItem] {
        [.auto()] + ComposerCatalog.focalSteps(c).map { mm in
            let f = c.focals.first { $0.mm == mm }
            let name = "\(focalText(mm)) mm" + ((f?.description).map { $0.isEmpty ? "" : " · \($0)" } ?? "")
            return WheelItem(value: focalText(mm), name: name, caption: focalCaption(mm))
        }
    }

    public static func focalText(_ mm: Double) -> String { mm == mm.rounded() ? String(Int(mm)) : String(mm) }

    public static func focalIndex(_ mm: Double?, in items: [WheelItem]) -> Int {
        guard let mm else { return 0 }
        return items.firstIndex { $0.value == focalText(mm) } ?? 0
    }

    static func focalCaption(_ mm: Double) -> String {
        switch mm {
        case ..<20: return "Huge space, stretched edges"
        case ..<30: return "Room and story around her"
        case ..<45: return "Everyday, a touch wide"
        case ..<70: return "Like your eye sees"
        case ..<110: return "Flattering, tighter faces"
        default: return "Compressed, far away"
        }
    }

    static func apertureCaption(_ id: String) -> String {
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
    public var still: String?
    public var video: String?
    public init(still: String?, video: String? = nil) {
        self.still = still
        self.video = video
    }

    /// Moves share one neutral still (the same subject in every clip); the tile draws the move's arrow over it.
    public static let neutralMoveStill = "light-01-soft-cross"
    public static func move(_ m: SuiteMoveOption) -> PickerPreview { PickerPreview(still: neutralMoveStill) }
    public static func option(_ o: SuiteOption) -> PickerPreview { PickerPreview(still: o.render) }
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

    public init(tool: ComposerTool = .shot, tokens: PromptTokens = PromptTokens(), settings: ComposerSettings = ComposerSettings(), outfitId: String? = nil,
                quality: String = "draft", aspect: String = "9:16", duration: Int = 8, sound: Bool = true, speaking: ComposerSpeaking = .auto, takes: Int = 1,
                collapsed: String? = nil, directed: CameraSpec? = nil) {
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

    /// The shot request: the prompt and chips, the bottom bar, then the input slots this tier takes.
    public func request(_ slots: InputSlots, _ inputs: SuiteInputs) -> ShotRequest {
        var r = composerRequest(tokens, settings, quality: quality, aspectRatio: aspect, duration: duration, takes: takes, speaking: speaking.value, title: title)
        r.audio = sound
        if r.modelId != nil, r.outfitId == nil { r.outfitId = outfitId }
        if let d = directed { r.camera = d }
        return slots.apply(to: r, inputs)
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
