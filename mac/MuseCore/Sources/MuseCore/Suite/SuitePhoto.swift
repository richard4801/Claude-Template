import Foundation

// AI suite · the Photo tool (workstream 3, plans/video-composer.md "Photo tool", plans/api.md "PhotoRequest"). Photoshoot
// folded into the composer: CHARACTER (outfit inside), PRODUCT (optional) and up to 3 REFERENCES, the Style / Camera /
// Look / Lighting chips, and a Photos 1–4 count. Movement and tempo don't exist in a still, so they never leave the app.
// Server: server/api/src/suite/photo.ts.

/// POST /v1/suite/photos(/estimate). The server is strict: unknown fields are refused, so nil fields are left out.
public struct PhotoRequest: Codable, Hashable, Sendable {
    public static let maxCount = 4

    /// The character; nil = none (owner 2026-11-11): a reference image is then the photo to work from (server suite/photo.ts).
    public var modelId: String?
    public var outfitId: String?
    /// The scene and what she does (the composer's prompt without #move chips).
    public var prompt: String
    /// The composer's rig without movement or tempo.
    public var camera: CameraSpec?
    /// "Grade with this look" (on by default on the server); only sent when switched off.
    public var gradeLook: Bool?
    /// Photos in this run, 1–4.
    public var count: Int
    /// A Photo preset (a photo template id): it carries its own camera and light.
    public var presetId: String?
    public var productImage: ImageRef?
    /// Up to 3, each with what to take from it (pose, look, scene).
    public var references: [ShootRef]?
    public var seed: Int64?
    public var lockSeed: Bool?
    public var shuffleSeed: Int64?
    public var title: String?
    /// AI suite (workstream 1): the composer's full draft, stored on every still for "Reuse settings" (left out when nil).
    public var draft: SuiteDraft?
    /// Owner only: the photo model for this run (a Replicate `owner/name` or a custom `c_…`); nil = the studio's.
    public var imageModel: String?

    public init(modelId: String?, outfitId: String? = nil, prompt: String = "", camera: CameraSpec? = nil, gradeLook: Bool? = nil, count: Int = PhotoRequest.maxCount,
                presetId: String? = nil, productImage: ImageRef? = nil, references: [ShootRef]? = nil, seed: Int64? = nil, lockSeed: Bool? = nil,
                shuffleSeed: Int64? = nil, title: String? = nil) {
        self.modelId = modelId
        self.outfitId = outfitId
        self.prompt = prompt
        self.camera = camera
        self.gradeLook = gradeLook
        self.count = count
        self.presetId = presetId
        self.productImage = productImage
        self.references = references
        self.seed = seed
        self.lockSeed = lockSeed
        self.shuffleSeed = shuffleSeed
        self.title = title
    }

    /// What the server refuses, as a line to show (nil = fine).
    public var problem: String? {
        if !(1...PhotoRequest.maxCount).contains(count) { return "Pick 1 to \(PhotoRequest.maxCount) photos" }
        let refs = references ?? []
        if refs.count > ShootRef.max { return "Up to \(ShootRef.max) reference images" }
        if refs.contains(where: { !$0.isValid }) { return "Each reference needs a photo and at least one guide" }
        return nil
    }
}

/// The preset a Photo estimate ran with.
public struct PhotoPresetRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// POST /v1/suite/photos/estimate: the price (a shoot's: count × per photo), the still rig check and the Look. Holds nothing.
public struct PhotoEstimate: Codable, Hashable, Sendable {
    public var tool: String
    public var count: Int
    public var perPhoto: Double
    public var estimate: Double
    /// "about $0.24 · 4 photos"
    public var priceLine: String
    /// "Generate · 4 photos · $0.24"
    public var buttonLabel: String
    public var ok: Bool
    /// "Movement doesn’t apply to photos", "The preset sets its own camera and light".
    public var warnings: [String]
    /// The still rules only: deep_focus, wide_close, worm_close, look_clash, prompt_angle, prompt_size.
    public var rig: [RigWarning]
    public var look: SuiteLook?
    /// The still's prompt (absent with a preset).
    public var prompt: String?
    public var preset: PhotoPresetRef?

    public init(count: Int, perPhoto: Double, estimate: Double? = nil, priceLine: String? = nil, buttonLabel: String? = nil, ok: Bool = true, warnings: [String] = [],
                rig: [RigWarning] = [], look: SuiteLook? = nil, prompt: String? = nil, preset: PhotoPresetRef? = nil) {
        let total = estimate ?? perPhoto * Double(count)
        self.tool = "photo"
        self.count = count
        self.perPhoto = perPhoto
        self.estimate = total
        self.priceLine = priceLine ?? PhotoEstimate.priceLine(total, count: count)
        self.buttonLabel = buttonLabel ?? PhotoEstimate.buttonLabel(total, count: count)
        self.ok = ok
        self.warnings = warnings
        self.rig = rig
        self.look = look
        self.prompt = prompt
        self.preset = preset
    }

    enum CodingKeys: String, CodingKey { case tool, count, perPhoto, estimate, priceLine, buttonLabel, ok, warnings, rig, look, prompt, preset }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tool = c.v(.tool, "photo")
        count = c.v(.count, PhotoRequest.maxCount)
        perPhoto = c.v(.perPhoto, 0)
        estimate = c.v(.estimate, perPhoto * Double(count))
        priceLine = c.v(.priceLine, PhotoEstimate.priceLine(estimate, count: count))
        buttonLabel = c.v(.buttonLabel, PhotoEstimate.buttonLabel(estimate, count: count))
        ok = c.v(.ok, true)
        warnings = c.v(.warnings, [])
        rig = c.v(.rig, RigWarnings()).list
        look = c.o(.look)
        prompt = c.o(.prompt)
        preset = c.o(.preset)
    }

    public static func photos(_ n: Int) -> String { "\(n) photo\(n == 1 ? "" : "s")" }
    /// The server's `photoButton`: "Generate · 4 photos · $0.24".
    public static func buttonLabel(_ estimate: Double, count: Int) -> String { "Generate · \(photos(count)) · \(Pricing.money(estimate))" }
    /// "about $0.24 · 4 photos".
    public static func priceLine(_ estimate: Double, count: Int) -> String { "\(PhotoPricing.label(estimate)) · \(photos(count))" }

    /// The pricing popover reads a shot estimate: the photo's lines in that shape (no seconds, no tier).
    public var asShotEstimate: ShotEstimate {
        var e = ShotEstimate(quality: "photo", label: "Photo · \(PhotoEstimate.photos(count))", resolution: "", seconds: 0, takes: count, mode: "photo",
                             estimate: estimate, priceLine: priceLine, buttonLabel: buttonLabel, ok: ok, warnings: warnings, prompt: prompt, rig: rig)
        e.look = look
        return e
    }
}

/// POST /v1/suite/photos → `{tool: "photo", takes}`: the stills, saved as takes titled "Photo · …".
public struct PhotoResult: Codable, Hashable, Sendable {
    public var tool: String
    public var takes: [Take]
    /// The run as a job (WS19): running when started with `async`, done otherwise.
    public var job: Job?
    public init(takes: [Take], job: Job? = nil) {
        self.tool = "photo"
        self.takes = takes
        self.job = job
    }

    enum CodingKeys: String, CodingKey { case tool, takes, job }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tool = c.v(.tool, "photo")
        takes = c.v(.takes, [])
        job = c.o(.job)
    }
}

extension GeneratePrice {
    /// Photo: "—" until priced, else the estimate's own "Generate · 4 photos · $0.24".
    public static func photo(_ e: PhotoEstimate?) -> GeneratePrice {
        guard let e else { return .unknown }
        return e.ok ? .price(e.buttonLabel) : .problem(e.warnings.first ?? "These photos can't be made as set")
    }
}

// MARK: The composer → PhotoRequest

/// The Photo tool's own choices beside the shared composer draft.
public struct PhotoDraft: Hashable, Sendable {
    /// Photos in this run (the bottom bar's "Photos" pill), 1–4.
    public var count: Int
    /// The Photo preset (a photo template) the composer starts from; nil = the chips.
    public var presetId: String?
    /// Up to 3 references (pose, look, scene).
    public var references: [ShootRef]
    /// Owner only: the photo model picked on the Model pill (nil = Auto, the studio's photo model).
    public var imageModel: String?

    public init(count: Int = PhotoRequest.maxCount, presetId: String? = nil, references: [ShootRef] = [], imageModel: String? = nil) {
        self.imageModel = imageModel
        self.count = count
        self.presetId = presetId
        self.references = references
    }

    /// The Photos pill's choices.
    public static let counts = Array(1...PhotoRequest.maxCount)
}

extension ComposerSettings {
    /// The chips as a still's camera: Setup, Angle, Style (no tempo), Look and Lighting; never a move. With a preset, only
    /// the Look rides along (the preset sets its own camera and light, so those chips are locked). nil when all Auto.
    public func photoCameraSpec(preset: Bool = false) -> CameraSpec? {
        var s = self
        s.tempo = nil
        s.format = nil
        if preset {
            s = ComposerSettings(palette: palette, stock: stock, gradeLook: gradeLook)
        }
        guard var spec = s.cameraSpec(moves: []) else { return nil }
        spec.move = nil
        spec.mix = nil
        return spec
    }
}

extension PromptTokens {
    /// The prompt without #move chips (a still doesn't move).
    public var withoutMoves: PromptTokens { PromptTokens(parts.filter { $0.moveInfo == nil }) }
}

extension ComposerDraft {
    /// The Photo request for this draft: the character and outfit, the prompt (no #moves), the chips as a still's camera
    /// (no movement, no tempo), the photo count, the preset and the slots. Without a character (owner 2026-11-11) only
    /// with a reference image and no preset (the image is the photo to work from); nil otherwise.
    public func photoRequest(_ photo: PhotoDraft, product: ImageRef? = nil) -> PhotoRequest? {
        let model = tokens.characterId
        if model == nil && (photo.presetId != nil || !photo.references.contains(where: \.isValid)) { return nil }
        let preset = photo.presetId
        let s = settings
        // With a preset only the Look rides along; otherwise the owner's Directed camera (as a still) or the chips.
        let camera = preset != nil ? s.photoCameraSpec(preset: true) : (directed.map(PhotoRequest.still) ?? s.photoCameraSpec())
        var r = PhotoRequest(modelId: model, outfitId: model == nil ? nil : tokens.outfitId ?? outfitId, prompt: tokens.withoutMoves.promptText(), camera: camera,
                             count: min(max(photo.count, 1), PhotoRequest.maxCount), presetId: preset, productImage: model == nil ? nil : product)
        if !s.gradeLook && (s.palette != nil || s.stock != nil) { r.gradeLook = false }
        let refs = photo.references.filter(\.isValid).prefix(ShootRef.max)
        r.references = refs.isEmpty ? nil : Array(refs)
        let words = r.prompt.split(separator: " ").prefix(5).joined(separator: " ")
        r.title = words.isEmpty ? nil : words
        r.imageModel = photo.imageModel
        return r
    }

    /// What the Photo tool still needs before Generate, as a line to show; nil when it can go.
    public func photoMissing(_ photo: PhotoDraft, uploading: Bool = false) -> String? {
        if tokens.characterId == nil {
            if photo.presetId != nil { return "Presets need a character · pick one with @" }
            if !photo.references.contains(where: \.isValid) && !uploading { return "Pick a character or add an image" }
        }
        if uploading { return "Wait for the upload to finish" }
        return nil
    }
}

extension PhotoRequest {
    /// A Directed camera as a still: its moves, tempo, frame rate and shutter don't apply.
    static func still(_ c: CameraSpec) -> CameraSpec {
        var s = c
        s.move = nil
        s.mix = nil
        if var st = s.style {
            st.tempo = nil
            s.style = st
        }
        return s
    }
}

/// The rig check's choices for a photo (it dismisses a warning until these change).
extension RigChoices {
    public init(_ r: PhotoRequest) { self.init(camera: r.camera, speaking: nil) }
}

/// The rig-check rules that make sense for a still (server suite/photo.ts STILL_RULES).
public enum PhotoRig {
    public static let stillRules: Set<String> = ["deep_focus", "wide_close", "worm_close", "look_clash", "prompt_angle", "prompt_size"]
    public static func still(_ list: [RigWarning]) -> [RigWarning] { list.filter { stillRules.contains($0.id) } }
}
