import Foundation

/// Who the model is: the written look plus the locked character-sheet references.
public struct PromptIdentity: Equatable, Sendable {
    public var name: String
    public var look: String
    public var referenceCount: Int
    public var neverAdd: [String]
    /// The Identity LoRA trigger token ("sienna_v1") when the model's LoRA is trained and switched on (plans/lora-training.md).
    /// Photo prompts name the photo LoRA, the H3 prompt names the video LoRA. nil means references only.
    public var lora: String?

    public init(name: String, look: String, referenceCount: Int = 6, neverAdd: [String] = [], lora: String? = nil) {
        self.name = name
        self.look = look
        self.referenceCount = referenceCount
        self.neverAdd = neverAdd
        self.lora = lora
    }
}

/// The photoshoot inspector (Scene / Camera / Light / Prompt tabs).
public struct ShootSettings: Equatable, Sendable, Codable {
    public static let scenes = ["Rooftop · golden hour", "Bedroom mirror", "Café window", "Beach noon", "City night", "Studio white"]
    public static let shots = ["Close", "Medium", "Full", "Wide"]
    public static let lenses = [16, 24, 35, 50, 85]
    public static let apertures = ["f/1.4", "f/2.8", "f/5.6", "f/11"]
    public static let lights = ["Golden hour", "Overcast", "Ring light", "Window light", "Flash", "Neon night"]
    public static let grades = ["Phone-natural", "Warm film", "Editorial", "Muted"]

    public var scene = "Rooftop · golden hour"
    public var sceneCustom = ""
    public var shot = "Medium"
    public var lens = 35
    public var aperture = "f/2.8"
    public var light = "Golden hour"
    public var grade = "Phone-natural"
    public var direction = ""
    public var lockSeed = true

    public init() {}

    /// The scene actually used: custom text wins over the chip.
    public var effectiveScene: String {
        let c = sceneCustom.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? scene : c
    }

    public mutating func resetCamera() {
        shot = "Medium"
        lens = 35
        aperture = "f/2.8"
    }

    /// "Wide: more room in frame…" hint under the lens chips.
    public var lensHint: String {
        lens <= 24 ? "Wide: more room in frame, slight stretch at the edges."
            : lens >= 85 ? "Tele: flattering face, blurred background." : "Natural phone-camera look."
    }
}

/// One layer of a built prompt. `key` matches the prototype's slot names (identity, outfit, scene, …).
public struct PromptSlot: Equatable, Sendable, Identifiable {
    public var key: String
    public var text: String
    public var id: String { key }

    public init(_ key: String, _ text: String) {
        self.key = key
        self.text = text
    }

    /// The slot text without its "Label: " prefix, as shown in the "final prompt by slot" box (`pboxHTML`).
    public var body: String {
        guard let r = text.range(of: "^[A-Za-z ]+: ", options: .regularExpression) else { return text }
        return String(text[r.upperBound...])
    }
}

/// What the video prompt says about the person in the source clip. Naming their tattoos and rings lets H3 remove them.
public struct SourcePerformer: Equatable, Sendable {
    public var description: String
    public init(description: String) { self.description = description }
    /// The prototype's sample clip.
    public static let sample = SourcePerformer(description: "a young woman with a floral forearm tattoo and two silver rings")
    public static let generic = SourcePerformer(description: "the person dancing in the clip")
}

public struct VideoPromptInput: Equatable, Sendable {
    public var identity: PromptIdentity
    public var outfitName: String
    public var performer: SourcePerformer
    public var keepBackground: Bool
    public var backgroundMotion: String
    public var keepAudio: Bool
    public var spec: RenderSpec

    public init(identity: PromptIdentity, outfitName: String, performer: SourcePerformer = .sample, keepBackground: Bool = true,
                backgroundMotion: String = "subtle", keepAudio: Bool = true, spec: RenderSpec = RenderSpec()) {
        self.identity = identity
        self.outfitName = outfitName
        self.performer = performer
        self.keepBackground = keepBackground
        self.backgroundMotion = backgroundMotion
        self.keepAudio = keepAudio
        self.spec = spec
    }
}

/// The layered prompt engine from plans/prompt-system.md, worded exactly like prototype/desktop/desktop.js
/// (`shootPrompt`, `videoPrompt`). Users never write prompts from scratch; their choices fill slots and empty slots are dropped.
public enum PromptEngine {
    public static let houseStyle = "realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss"
    public static let globalNever = ["logos", "extra fingers", "warped jewellery"]

    static func identityLine(_ id: PromptIdentity) -> String {
        let n = id.referenceCount
        var refs = n == 1 ? "1 locked reference image" : "\(n) locked reference images"
        if let lora = id.lora { refs += " + LoRA \(lora) (photo)" }
        let look = id.look.trimmingCharacters(in: .whitespaces)
        return look.isEmpty ? "\(id.name). Identity from \(refs)." : "\(id.name): \(look). Identity from \(refs)."
    }

    /// Model never-add items followed by the global defaults, without blanks or duplicates.
    public static func neverList(_ id: PromptIdentity) -> [String] {
        var seen = Set<String>()
        return (id.neverAdd + globalNever).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Photoshoot prompt, slot by slot. `houseStyle` is editable in Settings → Render defaults.
    public static func shoot(identity: PromptIdentity, outfitName: String, settings s: ShootSettings, houseStyle: String = houseStyle) -> [PromptSlot] {
        var lensNote = ""
        if s.lens <= 24 { lensNote = ", slight wide-angle distortion" } else if s.lens >= 85 { lensNote = ", compressed background, creamy bokeh" }
        let dir = s.direction.trimmingCharacters(in: .whitespacesAndNewlines)
        var slots = [
            PromptSlot("identity", identityLine(identity)),
            PromptSlot("outfit", "Wearing: \(outfitName.lowercased()) (outfit reference set)."),
            PromptSlot("scene", "Scene: \(s.effectiveScene.lowercased())."),
            PromptSlot("camera", "Camera: \(s.shot.lowercased()) shot, \(s.lens)mm lens, \(s.aperture)\(lensNote)."),
            PromptSlot("light", "Light: \(s.light.lowercased()); grade: \(s.grade.lowercased())."),
        ]
        if !dir.isEmpty { slots.append(PromptSlot("direction", "Direction: \(dir)")) }
        let style = houseStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty { slots.append(PromptSlot("style", "Style: \(style).")) }
        slots.append(PromptSlot("negative", "Never add: \(neverList(identity).joined(separator: ", "))."))
        slots.append(PromptSlot("seed", s.lockSeed ? "Seed: locked (retakes keep the same look)." : "Seed: new each shot."))
        return slots
    }

    /// The whole photoshoot prompt as text (Copy, Edit as text).
    public static func shootText(identity: PromptIdentity, outfitName: String, settings: ShootSettings, houseStyle: String = houseStyle) -> String {
        shoot(identity: identity, outfitName: outfitName, settings: settings, houseStyle: houseStyle).map(\.text).joined(separator: "\n")
    }

    /// The structured MiniMax H3 Ref2VA prompt shown in the video studio (pro mode / "Show the prompt").
    public static func video(_ v: VideoPromptInput) -> String {
        let id = v.identity
        var refs = id.referenceCount == 1 ? "reference image 1" : "reference images 1–\(id.referenceCount)"
        if let lora = id.lora { refs += ", LoRA \(lora) video" }
        let look = id.look.trimmingCharacters(in: .whitespaces)
        let target = look.isEmpty ? id.name : "\(id.name), \(look)"
        let never = id.neverAdd.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let removal = never.isEmpty ? "" : " None of Subject 1's \(never.joined(separator: " or ")) remain."
        let bg = v.keepBackground ? "background" : "new background photo (\(v.backgroundMotion))"
        let steps = v.spec.engine == .viggle ? "4 (Fast · beta, fixed)" : "\(v.spec.steps)"
        return """
        subject_definitions:
          Subject 1: the performer in the source clip, \(v.performer.description).
          Target: \(target) (\(refs)).
        summary:
          Replace Subject 1 with \(id.name), keeping the exact motion, timing, camera and \(bg).
        retention_analysis:
          Keep: pose, choreography, hand positions, room, lighting\(v.keepAudio ? ", audio (fully_copy)" : "").
          Replace: face, hair, skin, body proportions, outfit.
        detailed_description:
          \(id.name) wears the \(v.outfitName.lowercased()) from the outfit reference images.\(removal)
        steps: \(steps) · clip: \(Pricing.trimNumJS(v.spec.lengthSec))s · takes: \(v.spec.takes)
        """
    }

    /// The video prompt as members see it: the same text without the "steps: 10 · " part (members never see steps).
    public static func memberView(_ videoPrompt: String) -> String {
        videoPrompt.replacingOccurrences(of: #"(?m)^(\s*)steps: [^·\n]*· "#, with: "$1", options: .regularExpression)
    }

    /// Character-sheet shot (plans/prompt-system.md §2), used by "Fill missing angles" and "Retake with AI".
    public static func sheetShot(identity: PromptIdentity, angle: SheetAngle, houseStyle: String = houseStyle) -> String {
        [identityLine(identity),
         "Task: \(angle.label.lowercased()) shot on a plain light-grey studio background, even soft light, neutral expression, \(angle.framing).",
         "Style: \(houseStyle).",
         "Never add: \(neverList(identity).joined(separator: ", ")).",
        ].joined(separator: "\n")
    }

    /// Outfit-set angle: identity + outfit + task, four angles on one seed.
    public static func outfitAngle(identity: PromptIdentity, outfit: String, mode: OutfitMode, angle: String) -> String {
        let source: String
        switch mode {
        case .describe: source = "Wearing: \(outfit.lowercased())."
        case .photo: source = "Wearing: the outfit in the product photo (reference image)."
        case .own: source = "Wearing: the outfit in the uploaded angle images."
        }
        return [identityLine(identity), source, "Task: \(angle.lowercased()) view, full body, plain studio background.", "Seed: shared across all four angles.", "Never add: logos."].joined(separator: "\n")
    }
}

extension Pricing {
    /// JS template-literal number printing for the clip length (5.2 → "5.2", 9.4 → "9.4", 15 → "15").
    static func trimNumJS(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        // Shortest round-trip representation, like JS.
        return "\(v)"
    }
}

/// The six character-sheet slots.
public enum SheetAngle: String, CaseIterable, Codable, Sendable, Identifiable {
    case face, profile, front, tq, side, back
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .face: return "Face · front"
        case .profile: return "Face · profile"
        case .front: return "Body · front"
        case .tq: return "Body · ¾"
        case .side: return "Body · side"
        case .back: return "Body · back"
        }
    }

    public var framing: String {
        switch self {
        case .face: return "head-and-shoulders, facing the camera"
        case .profile: return "head-and-shoulders, side profile"
        case .front: return "full body, facing the camera"
        case .tq: return "full body, three-quarter view"
        case .side: return "full body, side view"
        case .back: return "full body, from behind"
        }
    }

    public var isFace: Bool { self == .face || self == .profile }
}

/// How an outfit set is made: Describe it / From a photo / My own set.
public enum OutfitMode: String, CaseIterable, Codable, Sendable {
    case describe, photo, own
    public var label: String {
        switch self {
        case .describe: return "Describe it"
        case .photo: return "From a photo"
        case .own: return "My own set"
        }
    }
}

