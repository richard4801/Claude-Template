import Foundation

// Editor v2: the multitrack edit project (plans/video-editor.md "Editor v2 (engine contract)"). A Swift port of the
// reference implementation server/api/src/editor/model.ts: the JSON field names are the contract's, absent optionals are
// left out when encoding, and every function in EditV2 gives the reference's answers for the shared fixtures
// (Tests/MuseCoreTests/Fixtures/editor). Everything lives in the `EditV2` namespace so nothing clashes with the v1 editor.

public enum EditV2 {}

extension EditV2 {
    public enum Ease: String, Codable, Hashable, Sendable, CaseIterable { case linear, easeIn, easeOut, easeInOut, hold }

    public struct Keyframe: Codable, Hashable, Sendable {
        /// Seconds from the item's own start on the timeline.
        public var t: Double
        public var v: Double
        public var ease: Ease?
        public init(t: Double, v: Double, ease: Ease? = nil) { self.t = t; self.v = v; self.ease = ease }
    }

    public enum KfProp: String, Codable, Hashable, Sendable, CaseIterable {
        case x, y, scale, rotation, opacity, volume
        /// Colour keyframes (contract, WS8 c10e398): replace the adjust field's static value over time (`adjustAt`).
        case exposure, contrast, saturation, temperature, tint
        /// Mask keyframes (contract, WS8 bfa44a6): replace the mask's field over time (`maskAt`); only on items with a mask.
        case maskX, maskY, maskWidth, maskHeight, maskRotation, maskFeather
        /// Look keyframes: the finishing effects' amounts over time (`lookAt`).
        case vignette, grain, leak
        /// The colour properties, in the contract's order (COLOR_KF_PROPS).
        public static let color: [KfProp] = [.exposure, .contrast, .saturation, .temperature, .tint]
        public static let mask: [KfProp] = [.maskX, .maskY, .maskWidth, .maskHeight, .maskRotation, .maskFeather]
        public static let look: [KfProp] = [.vignette, .grain, .leak]
        public var isColor: Bool { KfProp.color.contains(self) }
        public var isMask: Bool { KfProp.mask.contains(self) }
        public var isLook: Bool { KfProp.look.contains(self) }
    }

    public struct Keyframes: Codable, Hashable, Sendable {
        public var x: [Keyframe]?
        public var y: [Keyframe]?
        public var scale: [Keyframe]?
        public var rotation: [Keyframe]?
        public var opacity: [Keyframe]?
        public var volume: [Keyframe]?
        public var exposure: [Keyframe]?
        public var contrast: [Keyframe]?
        public var saturation: [Keyframe]?
        public var temperature: [Keyframe]?
        public var tint: [Keyframe]?
        public var maskX: [Keyframe]?
        public var maskY: [Keyframe]?
        public var maskWidth: [Keyframe]?
        public var maskHeight: [Keyframe]?
        public var maskRotation: [Keyframe]?
        public var maskFeather: [Keyframe]?
        public var vignette: [Keyframe]?
        public var grain: [Keyframe]?
        public var leak: [Keyframe]?
        public init(x: [Keyframe]? = nil, y: [Keyframe]? = nil, scale: [Keyframe]? = nil, rotation: [Keyframe]? = nil,
                    opacity: [Keyframe]? = nil, volume: [Keyframe]? = nil) {
            self.x = x; self.y = y; self.scale = scale; self.rotation = rotation; self.opacity = opacity; self.volume = volume
        }
        public subscript(_ p: KfProp) -> [Keyframe]? {
            get {
                switch p {
                case .x: return x
                case .y: return y
                case .scale: return scale
                case .rotation: return rotation
                case .opacity: return opacity
                case .volume: return volume
                case .exposure: return exposure
                case .contrast: return contrast
                case .saturation: return saturation
                case .temperature: return temperature
                case .tint: return tint
                case .maskX: return maskX
                case .maskY: return maskY
                case .maskWidth: return maskWidth
                case .maskHeight: return maskHeight
                case .maskRotation: return maskRotation
                case .maskFeather: return maskFeather
                case .vignette: return vignette
                case .grain: return grain
                case .leak: return leak
                }
            }
            set {
                switch p {
                case .x: x = newValue
                case .y: y = newValue
                case .scale: scale = newValue
                case .rotation: rotation = newValue
                case .opacity: opacity = newValue
                case .volume: volume = newValue
                case .exposure: exposure = newValue
                case .contrast: contrast = newValue
                case .saturation: saturation = newValue
                case .temperature: temperature = newValue
                case .tint: tint = newValue
                case .maskX: maskX = newValue
                case .maskY: maskY = newValue
                case .maskWidth: maskWidth = newValue
                case .maskHeight: maskHeight = newValue
                case .maskRotation: maskRotation = newValue
                case .maskFeather: maskFeather = newValue
                case .vignette: vignette = newValue
                case .grain: grain = newValue
                case .leak: leak = newValue
                }
            }
        }
        /// The properties that have a list, in KfProp order.
        public var present: [(KfProp, [Keyframe])] { KfProp.allCases.compactMap { p in self[p].map { (p, $0) } } }
        public var isEmpty: Bool { present.isEmpty }
    }

    public struct Transform: Codable, Hashable, Sendable {
        public var x: Double?
        public var y: Double?
        public var scale: Double?
        public var rotation: Double?
        /// Wave 1 (mirror): the picture mirrored about its own centre, after the crop and before scale and rotation. Only true is written.
        public var flipX: Bool?
        public var flipY: Bool?
        public init(x: Double? = nil, y: Double? = nil, scale: Double? = nil, rotation: Double? = nil, flipX: Bool? = nil, flipY: Bool? = nil) {
            self.x = x; self.y = y; self.scale = scale; self.rotation = rotation; self.flipX = flipX; self.flipY = flipY
        }
    }

    /// Wave 1: how a picture on an overlay track combines with the layers below it (`blendPixel`).
    public enum BlendMode: String, Codable, Hashable, Sendable, CaseIterable {
        case normal, multiply, screen, overlay, softLight, darken, lighten, add
    }

    /// Wave 1: what shows where a contain-fitted main clip leaves the frame empty.
    public enum CanvasFill: String, Codable, Hashable, Sendable { case color, blur }

    public struct Crop: Codable, Hashable, Sendable {
        public var left: Double?
        public var top: Double?
        public var right: Double?
        public var bottom: Double?
        public init(left: Double? = nil, top: Double? = nil, right: Double? = nil, bottom: Double? = nil) {
            self.left = left; self.top = top; self.right = right; self.bottom = bottom
        }
    }

    public struct Adjust: Codable, Hashable, Sendable {
        public var exposure: Double?
        public var contrast: Double?
        public var saturation: Double?
        public var temperature: Double?
        /// Edit suite: tone after the colour matrix (`toneAdjust`), −1…1.
        public var highlights: Double?
        public var shadows: Double?
        /// Parity: green (−1) ↔ magenta (+1), right after temperature in the colour matrix.
        public var tint: Double?
        public init(exposure: Double? = nil, contrast: Double? = nil, saturation: Double? = nil, temperature: Double? = nil,
                    highlights: Double? = nil, shadows: Double? = nil, tint: Double? = nil) {
            self.exposure = exposure; self.contrast = contrast; self.saturation = saturation; self.temperature = temperature
            self.highlights = highlights; self.shadows = shadows; self.tint = tint
        }
        /// A colour keyframe property's field (nil for the other KfProps).
        public subscript(_ p: KfProp) -> Double? {
            get {
                switch p {
                case .exposure: return exposure
                case .contrast: return contrast
                case .saturation: return saturation
                case .temperature: return temperature
                case .tint: return tint
                default: return nil
                }
            }
            set {
                switch p {
                case .exposure: exposure = newValue
                case .contrast: contrast = newValue
                case .saturation: saturation = newValue
                case .temperature: temperature = newValue
                case .tint: tint = newValue
                default: break
                }
            }
        }
    }

    public struct FilterRef: Codable, Hashable, Sendable {
        public var id: String
        public var amount: Double
        public init(id: String, amount: Double) { self.id = id; self.amount = amount }
    }

    /// A clip's alpha from a matte video (white = opaque; `invert`: black = opaque), sampled at the clip's own source time and
    /// applied before its look, mask and transform (plans/api.md "VideoClip.alphaMatte").
    public struct AlphaMatte: Codable, Hashable, Sendable {
        public var asset: String
        public var invert: Bool?
        public init(asset: String, invert: Bool? = nil) { self.asset = asset; self.invert = invert }
    }

    public struct Chroma: Codable, Hashable, Sendable {
        public var color: String
        public var similarity: Double?
        public var smoothness: Double?
        public var spill: Double?
        public init(color: String, similarity: Double? = nil, smoothness: Double? = nil, spill: Double? = nil) {
            self.color = color; self.similarity = similarity; self.smoothness = smoothness; self.spill = spill
        }
    }

    public enum TransitionKind: String, Codable, Hashable, Sendable, CaseIterable {
        case fade, black, white, slideLeft, slideRight, slideUp, slideDown, zoom
        /// Edit suite additions.
        case whip, spin, glitch
        /// Content pack (WS8 929bcf2): made of the same layer values.
        case zoomOut, whipRight, coverLeft, coverRight, coverUp, coverDown, splitFade
    }

    /// Speed-curve preset (`custom` = edited points). Decodes any string so validate() can name an unknown one.
    public struct SpeedPreset: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
        public var description: String { rawValue }
        public static let montage = SpeedPreset(rawValue: "montage"), hero = SpeedPreset(rawValue: "hero"), bullet = SpeedPreset(rawValue: "bullet")
        public static let flashIn = SpeedPreset(rawValue: "flashIn"), flashOut = SpeedPreset(rawValue: "flashOut"), custom = SpeedPreset(rawValue: "custom")
        public static let all: [SpeedPreset] = [.montage, .hero, .bullet, .flashIn, .flashOut, .custom]
    }

    /// A speed curve over the clip's kept source: points [x 0–1, speed 0.1–10], x from 0 to 1, rising.
    public struct SpeedCurve: Codable, Hashable, Sendable {
        public var preset: SpeedPreset
        public var points: [[Double]]
        public init(preset: SpeedPreset, points: [[Double]]) { self.preset = preset; self.points = points }
    }

    /// Mask shape (decodes any string, see SpeedPreset).
    public struct MaskShape: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
        public var description: String { rawValue }
        public static let linear = MaskShape(rawValue: "linear"), mirror = MaskShape(rawValue: "mirror"), circle = MaskShape(rawValue: "circle")
        public static let rect = MaskShape(rawValue: "rect"), heart = MaskShape(rawValue: "heart"), star = MaskShape(rawValue: "star")
        public static let all: [MaskShape] = [.linear, .mirror, .circle, .rect, .heart, .star]
    }

    /// A mask on a video/image item: centre and size in item fractions, rotation in degrees, soft edge, inverted or not.
    public struct Mask: Codable, Hashable, Sendable {
        public var shape: MaskShape
        public var x: Double?
        public var y: Double?
        public var width: Double?
        public var height: Double?
        public var rotation: Double?
        public var feather: Double?
        public var invert: Bool?
        public init(shape: MaskShape, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil, rotation: Double? = nil,
                    feather: Double? = nil, invert: Bool? = nil) {
            self.shape = shape; self.x = x; self.y = y; self.width = width; self.height = height; self.rotation = rotation
            self.feather = feather; self.invert = invert
        }
    }

    /// Voice effect on a clip with sound (decodes any string, see SpeedPreset).
    public struct VoiceEffect: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
        public var description: String { rawValue }
        public static let none = VoiceEffect(rawValue: "none"), warm = VoiceEffect(rawValue: "warm"), radio = VoiceEffect(rawValue: "radio")
        public static let phone = VoiceEffect(rawValue: "phone"), deep = VoiceEffect(rawValue: "deep")
        public static let all: [VoiceEffect] = [.none, .warm, .radio, .phone, .deep]
    }

    public struct Transition: Codable, Hashable, Sendable {
        public var kind: TransitionKind
        public var durationSec: Double
        public init(kind: TransitionKind, durationSec: Double) { self.kind = kind; self.durationSec = durationSec }
    }

    public enum AnimKind: String, Codable, Hashable, Sendable, CaseIterable { case none, fade, pop, slideUp, slideDown, zoom, typewriter }

    public struct Anim: Codable, Hashable, Sendable {
        public var kind: AnimKind
        public var durationSec: Double
        public init(kind: AnimKind, durationSec: Double) { self.kind = kind; self.durationSec = durationSec }
    }

    /// Loop animation kinds; kept as a string so an unknown kind reaches validation ("unknown loop animation").
    public struct LoopKind: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
        public var description: String { rawValue }
        public static let pulse = LoopKind(rawValue: "pulse"), sway = LoopKind(rawValue: "sway"), float = LoopKind(rawValue: "float")
        public static let spin = LoopKind(rawValue: "spin"), blink = LoopKind(rawValue: "blink")
        public static let all: [LoopKind] = [.pulse, .sway, .float, .spin, .blink]
        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// A repeating move: period 0.2–5 s, amount 0–1 (default 0.5; spin ignores it).
    public struct AnimLoop: Codable, Hashable, Sendable {
        public var kind: LoopKind
        public var periodSec: Double
        public var amount: Double?
        public init(kind: LoopKind, periodSec: Double, amount: Double? = nil) { self.kind = kind; self.periodSec = periodSec; self.amount = amount }
    }

    public enum Fit: String, Codable, Hashable, Sendable { case cover, contain }

    /// `lut` = an imported .cube (Looks); it must be an `upload`.
    public enum AssetKind: String, Codable, Hashable, Sendable { case video, image, audio, lut, font /* own fonts (WS8 6ccd9aa): a .ttf / .otf upload */ }

    public struct Asset: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var kind: AssetKind
        /// Exactly one of take / upload / library.
        public var take: String?
        public var upload: String?
        public var library: String?
        public var durationSec: Double?
        public var width: Int?
        public var height: Int?
        public var hasAudio: Bool?
        /// A hint, never trusted.
        public var url: String?
        /// A font asset's family and style, read from the file (display only), 1–80 characters.
        public var name: String?
        /// Reverse (WS8 cb5413e): this video asset is that video asset played backwards.
        public var reverseOf: String?
        /// A video asset made from another by a helper (WS8 2df521a): stabilize (same length and timing) or slowmo (a range
        /// with frames interpolated, factor× as long, silent).
        public var derivedFrom: DerivedFrom?
        public init(id: String, kind: AssetKind, take: String? = nil, upload: String? = nil, library: String? = nil, durationSec: Double? = nil,
                    width: Int? = nil, height: Int? = nil, hasAudio: Bool? = nil, url: String? = nil, name: String? = nil) {
            self.id = id; self.kind = kind; self.take = take; self.upload = upload; self.library = library; self.durationSec = durationSec
            self.width = width; self.height = height; self.hasAudio = hasAudio; self.url = url; self.name = name
        }
    }

    /// The effects library (WS8 f7226f2, effects.ts): one in-house picture effect. `id` stays a string so validation can
    /// name an unknown one; amount 0–1 (0 is the identity), speed 0.1–4 for the moving ones, two colours for duotone.
    public struct Effect: Codable, Hashable, Sendable {
        public var id: String
        public var amount: Double
        public var speed: Double?
        public var colors: [String]?
        public init(id: String, amount: Double, speed: Double? = nil, colors: [String]? = nil) { self.id = id; self.amount = amount; self.speed = speed; self.colors = colors }
    }
    public static let effectIds = ["glitch", "vhs", "film", "blur", "zoomBlur", "mirror", "pixelate", "posterize", "duotone", "shake", "flash", "rain"]
    /// Effects whose look moves over time (they take a speed).
    public static let effectSpeedIds = ["glitch", "vhs", "film", "shake", "flash", "rain"]
    public static let duotoneDefault = ["#1B1464", "#FF6B6B"]

    public enum DerivedOp: String, Codable, Hashable, Sendable, CaseIterable { case stabilize, slowmo }
    /// How a helper copy was made. `op` stays a string so validation can name an unknown one; the range fields belong to
    /// slowmo only (validation refuses them on a steadied copy).
    public struct DerivedFrom: Codable, Hashable, Sendable {
        public var asset: String
        public var op: String
        public var startSec: Double?
        public var endSec: Double?
        public var factor: Double?
        public init(asset: String, op: DerivedOp, startSec: Double? = nil, endSec: Double? = nil, factor: Double? = nil) {
            self.asset = asset; self.op = op.rawValue; self.startSec = startSec; self.endSec = endSec; self.factor = factor
        }
        public var kind: DerivedOp? { DerivedOp(rawValue: op) }
    }
    public static let slowmoFactors: [Double] = [2, 4], slowmoMinRangeSec = 0.3, slowmoMaxRangeSec = 10.0

    /// A clip on the main track (back to back, no startSec) or an overlay video (`video` track, with startSec).
    public struct VideoClip: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var asset: String
        public var inSec: Double
        public var outSec: Double
        public var speed: Double
        public var startSec: Double?
        public var volume: Double?
        public var muted: Bool?
        public var fadeInSec: Double?
        public var fadeOutSec: Double?
        public var audioAsset: String?
        public var fit: Fit?
        public var transform: Transform?
        public var crop: Crop?
        public var opacity: Double?
        public var keyframes: Keyframes?
        public var filter: FilterRef?
        public var adjust: Adjust?
        /// The filter stack (EditV2Looks.swift).
        public var look: Look?
        public var chroma: Chroma?
        /// The effects library (WS8 f7226f2): one picture effect, after the look, before the mask and transform.
        public var effect: Effect?
        public var transitionIn: Transition?
        /// Edit suite: a speed curve (replaces `speed` for timing), a mask, voice processing.
        public var speedCurve: SpeedCurve?
        public var mask: Mask?
        public var voiceEffect: VoiceEffect?
        public var enhance: Bool?
        /// Remove background (workstream 1 contract, 2026-11-08): a grey matte video aligned with `asset`; its luma is the alpha.
        public var alphaMatte: AlphaMatte?
        /// Layers (plans/layers-edit.md, Phase 1; main clips only): tracked objects drawn again over the clip (EditV2Layers.swift).
        public var layers: [ClipLayer]?
        /// The "Background" row of a clip with layers.
        public var layerBase: LayerBase?
        /// The Find layers job the layers came from (not drawn).
        public var layerSource: LayerSource?
        /// Wave 1, freeze frame: the clip shows the single source frame at inSec for holdSec seconds, silent (clipLength = holdSec).
        public var holdSec: Double?
        /// Wave 1: overlay tracks only.
        public var blend: BlendMode?
        /// In / out animation (as pictures: fade, pop, slideUp, slideDown, zoom), main or overlay; animState over clipLength.
        public var animIn: Anim?
        public var animOut: Anim?
        /// Loop animation (contract, WS8 57fe40c): a repeating move while it's on screen (overlays, images, text; not main).
        public var animLoop: AnimLoop?
        public init(id: String, asset: String, inSec: Double, outSec: Double, speed: Double = 1, startSec: Double? = nil, volume: Double? = nil,
                    muted: Bool? = nil, fadeInSec: Double? = nil, fadeOutSec: Double? = nil, audioAsset: String? = nil, fit: Fit? = nil,
                    transform: Transform? = nil, crop: Crop? = nil, opacity: Double? = nil, keyframes: Keyframes? = nil, filter: FilterRef? = nil,
                    adjust: Adjust? = nil, look: Look? = nil, chroma: Chroma? = nil, transitionIn: Transition? = nil, speedCurve: SpeedCurve? = nil,
                    mask: Mask? = nil, voiceEffect: VoiceEffect? = nil, enhance: Bool? = nil) {
            self.speedCurve = speedCurve; self.mask = mask; self.voiceEffect = voiceEffect; self.enhance = enhance
            self.id = id; self.asset = asset; self.inSec = inSec; self.outSec = outSec; self.speed = speed; self.startSec = startSec
            self.volume = volume; self.muted = muted; self.fadeInSec = fadeInSec; self.fadeOutSec = fadeOutSec; self.audioAsset = audioAsset
            self.fit = fit; self.transform = transform; self.crop = crop; self.opacity = opacity; self.keyframes = keyframes
            self.filter = filter; self.adjust = adjust; self.look = look; self.chroma = chroma; self.transitionIn = transitionIn
        }
    }

    public struct ImageItem: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var asset: String
        public var startSec: Double
        public var durationSec: Double
        public var fit: Fit?
        public var transform: Transform?
        public var crop: Crop?
        public var opacity: Double?
        public var keyframes: Keyframes?
        public var filter: FilterRef?
        public var adjust: Adjust?
        /// The filter stack (EditV2Looks.swift).
        public var look: Look?
        public var animIn: Anim?
        public var animOut: Anim?
        /// Loop animation (contract, WS8 57fe40c): a repeating move while it's on screen (overlays, images, text; not main).
        /// The effects library (WS8 f7226f2).
        public var effect: Effect?
        /// A cross-dissolve from the previous image on its track (kind fade; it overlaps that one by durationSec, WS8 3d62419).
        public var transitionIn: Transition?
        public var animLoop: AnimLoop?
        /// Edit suite.
        public var mask: Mask?
        /// Wave 1.
        public var blend: BlendMode?
        public init(id: String, asset: String, startSec: Double, durationSec: Double, fit: Fit? = nil, transform: Transform? = nil, crop: Crop? = nil,
                    opacity: Double? = nil, keyframes: Keyframes? = nil, filter: FilterRef? = nil, adjust: Adjust? = nil, look: Look? = nil,
                    animIn: Anim? = nil, animOut: Anim? = nil, mask: Mask? = nil) {
            self.mask = mask
            self.id = id; self.asset = asset; self.startSec = startSec; self.durationSec = durationSec; self.fit = fit; self.transform = transform
            self.crop = crop; self.opacity = opacity; self.keyframes = keyframes; self.filter = filter; self.adjust = adjust; self.look = look
            self.animIn = animIn; self.animOut = animOut
        }
    }

    public enum Font: String, Codable, Hashable, Sendable, CaseIterable {
        case sans, serif, rounded, condensed, mono, marker
        /// The content library's families (catalog `fonts` pack; Cyrillic and Latin Extended), WS8 929bcf2.
        case inter, montserrat, robotoCondensed, playfair, unbounded, rubik, jetbrainsMono, caveat, oswald
        /// The six bundled families.
        public static let bundled: [Font] = [.sans, .serif, .rounded, .condensed, .mono, .marker]
        public var isContent: Bool { !Font.bundled.contains(self) }
        /// The bundled family a content font draws in until its file is on this Mac (model.ts FONT_FALLBACK).
        public var fallback: Font {
            switch self {
            case .inter, .montserrat, .unbounded: return .sans
            case .robotoCondensed, .oswald: return .condensed
            case .playfair: return .serif
            case .rubik: return .rounded
            case .jetbrainsMono: return .mono
            case .caveat: return .marker
            default: return self
            }
        }
        public var label: String {
            switch self {
            case .robotoCondensed: return "Roboto Condensed"
            case .jetbrainsMono: return "JetBrains Mono"
            default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
            }
        }
    }
    public enum Align: String, Codable, Hashable, Sendable { case left, center, right }

    public struct Stroke: Codable, Hashable, Sendable {
        public var color: String
        /// Of the font size, 0–0.3.
        public var widthPct: Double
        public init(color: String, widthPct: Double) { self.color = color; self.widthPct = widthPct }
    }

    public struct Shadow: Codable, Hashable, Sendable {
        public var color: String
        public var opacity: Double
        public var blurPct: Double
        public var dyPct: Double
        public init(color: String, opacity: Double, blurPct: Double, dyPct: Double) {
            self.color = color; self.opacity = opacity; self.blurPct = blurPct; self.dyPct = dyPct
        }
    }

    public struct TextBackground: Codable, Hashable, Sendable {
        public var color: String
        public var opacity: Double
        public var paddingPct: Double
        public var radiusPct: Double
        public init(color: String, opacity: Double, paddingPct: Double, radiusPct: Double) {
            self.color = color; self.opacity = opacity; self.paddingPct = paddingPct; self.radiusPct = radiusPct
        }
    }

    public struct TextStyle: Codable, Hashable, Sendable {
        /// A copy with `fontAsset` set.
        public func with(fontAsset f: String?) -> TextStyle { var c = self; c.fontAsset = f; return c }
        public var font: Font
        /// 400, 700 or 900.
        public var weight: Int
        /// Of the canvas height, 0.015–0.25.
        public var sizePct: Double
        public var color: String
        public var align: Align
        public var maxWidthPct: Double?
        public var lineHeight: Double?
        public var letterSpacing: Double?
        public var uppercase: Bool?
        public var stroke: Stroke?
        public var shadow: Shadow?
        public var background: TextBackground?
        /// Text items only: a `font` asset drawn as is (its own face; `weight` isn't synthesised); `font` stays the fallback.
        public var fontAsset: String?
        public init(font: Font = .sans, weight: Int = 900, sizePct: Double = 0.045, color: String = "#FFFFFF", align: Align = .center,
                    maxWidthPct: Double? = nil, lineHeight: Double? = nil, letterSpacing: Double? = nil, uppercase: Bool? = nil,
                    stroke: Stroke? = nil, shadow: Shadow? = nil, background: TextBackground? = nil) {
            self.font = font; self.weight = weight; self.sizePct = sizePct; self.color = color; self.align = align; self.maxWidthPct = maxWidthPct
            self.lineHeight = lineHeight; self.letterSpacing = letterSpacing; self.uppercase = uppercase; self.stroke = stroke
            self.shadow = shadow; self.background = background
        }
    }

    public struct TextItem: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var startSec: Double
        public var durationSec: Double
        /// 1–500 characters, "\n" = new line.
        public var text: String
        public var style: TextStyle
        public var transform: Transform?
        public var opacity: Double?
        public var keyframes: Keyframes?
        public var animIn: Anim?
        public var animOut: Anim?
        /// Loop animation (contract, WS8 57fe40c): a repeating move while it's on screen (overlays, images, text; not main).
        public var animLoop: AnimLoop?
        /// The hook template it was made from.
        public var template: String?
        /// Layers: the text's centre follows a tracked layer (pinPoint).
        public var pin: TextPin?
        public init(id: String, startSec: Double, durationSec: Double, text: String, style: TextStyle, transform: Transform? = nil,
                    opacity: Double? = nil, keyframes: Keyframes? = nil, animIn: Anim? = nil, animOut: Anim? = nil, template: String? = nil) {
            self.id = id; self.startSec = startSec; self.durationSec = durationSec; self.text = text; self.style = style
            self.transform = transform; self.opacity = opacity; self.keyframes = keyframes; self.animIn = animIn; self.animOut = animOut
            self.template = template
        }
    }

    public struct AudioClip: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var asset: String
        public var startSec: Double
        public var inSec: Double
        public var outSec: Double
        public var speed: Double?
        public var volume: Double?
        public var muted: Bool?
        public var fadeInSec: Double?
        public var fadeOutSec: Double?
        /// Volume only.
        public var keyframes: Keyframes?
        /// Beat marks, source seconds.
        public var beats: [Double]?
        /// Edit suite: the strong (bar) beats, voice processing.
        public var strongBeats: [Double]?
        public var voiceEffect: VoiceEffect?
        public var enhance: Bool?
        public init(id: String, asset: String, startSec: Double, inSec: Double, outSec: Double, speed: Double? = nil, volume: Double? = nil,
                    muted: Bool? = nil, fadeInSec: Double? = nil, fadeOutSec: Double? = nil, keyframes: Keyframes? = nil, beats: [Double]? = nil,
                    strongBeats: [Double]? = nil, voiceEffect: VoiceEffect? = nil, enhance: Bool? = nil) {
            self.strongBeats = strongBeats; self.voiceEffect = voiceEffect; self.enhance = enhance
            self.id = id; self.asset = asset; self.startSec = startSec; self.inSec = inSec; self.outSec = outSec; self.speed = speed
            self.volume = volume; self.muted = muted; self.fadeInSec = fadeInSec; self.fadeOutSec = fadeOutSec; self.keyframes = keyframes
            self.beats = beats
        }
    }

    public enum CaptionPreset: String, Codable, Hashable, Sendable, CaseIterable { case plain, highlight, box, karaoke, pop, single, highlighter, neon }

    /// TextStyle fields plus the caption ones (flat in JSON, as in the contract).
    public struct CaptionStyle: Codable, Hashable, Sendable {
        public var font: Font
        public var weight: Int
        public var sizePct: Double
        public var color: String
        public var align: Align
        public var maxWidthPct: Double?
        public var lineHeight: Double?
        public var letterSpacing: Double?
        public var uppercase: Bool?
        public var stroke: Stroke?
        public var shadow: Shadow?
        public var background: TextBackground?
        /// Refused on captions (they use the built-in fonts); decoded so validation can say so.
        public var fontAsset: String?
        public var preset: CaptionPreset
        public var highlightColor: String
        /// Centre, 0–1 (default 0.72).
        public var y: Double?
        public var wordsPerPage: Double?
        public var maxLines: Double?

        public init(_ s: TextStyle, preset: CaptionPreset, highlightColor: String, y: Double? = nil, wordsPerPage: Double? = nil, maxLines: Double? = nil) {
            font = s.font; weight = s.weight; sizePct = s.sizePct; color = s.color; align = s.align; maxWidthPct = s.maxWidthPct
            lineHeight = s.lineHeight; letterSpacing = s.letterSpacing; uppercase = s.uppercase; stroke = s.stroke; shadow = s.shadow
            background = s.background; fontAsset = s.fontAsset
            self.preset = preset; self.highlightColor = highlightColor; self.y = y; self.wordsPerPage = wordsPerPage; self.maxLines = maxLines
        }

        /// The TextStyle part.
        public var textStyle: TextStyle {
            TextStyle(font: font, weight: weight, sizePct: sizePct, color: color, align: align, maxWidthPct: maxWidthPct, lineHeight: lineHeight,
                      letterSpacing: letterSpacing, uppercase: uppercase, stroke: stroke, shadow: shadow, background: background)
                .with(fontAsset: fontAsset)
        }
    }

    public struct CaptionWord: Codable, Hashable, Sendable {
        public var text: String
        /// SOURCE seconds of the caption track's asset.
        public var startSec: Double
        public var endSec: Double
        public init(text: String, startSec: Double, endSec: Double) { self.text = text; self.startSec = startSec; self.endSec = endSec }
    }

    public struct CaptionTrack: Codable, Hashable, Sendable {
        public var asset: String
        public var words: [CaptionWord]
        public var style: CaptionStyle
        /// Translated captions (WS8 cac2bb0): the words' language (e.g. "es"), and the words they were translated from.
        public var language: String?
        public var original: CaptionOriginal?
        public init(asset: String, words: [CaptionWord], style: CaptionStyle, language: String? = nil, original: CaptionOriginal? = nil) {
            self.asset = asset; self.words = words; self.style = style; self.language = language; self.original = original
        }
    }

    public struct CaptionOriginal: Codable, Hashable, Sendable {
        public var language: String?
        public var words: [CaptionWord]
        public init(language: String? = nil, words: [CaptionWord]) { self.language = language; self.words = words }
    }

    public static let languageCodePattern = #"^[a-z]{2,3}(-[A-Z]{2})?$"#
    public static func isLanguageCode(_ s: String) -> Bool { s.range(of: languageCodePattern, options: .regularExpression) != nil }

    /// The caption track shown in its original words (and back): words and language swap with `original`'s; unchanged
    /// without one.
    public static func swapCaptionOriginal(_ ct: CaptionTrack) -> CaptionTrack {
        guard let o = ct.original else { return ct }
        var out = ct
        out.words = o.words
        out.language = o.language
        out.original = CaptionOriginal(language: ct.language, words: ct.words)
        return out
    }

    /// The caption track with translated `words` in `language`; the first original is kept (translating again replaces
    /// only the translation).
    public static func translateCaptions(_ ct: CaptionTrack, language: String, words: [CaptionWord], sourceLanguage: String? = nil) -> CaptionTrack {
        var out = ct
        out.original = ct.original ?? CaptionOriginal(language: ct.language ?? sourceLanguage, words: ct.words)
        out.words = words
        out.language = language
        return out
    }

    public enum DuckSource: String, Codable, Hashable, Sendable { case voice, speech }

    public struct Duck: Codable, Hashable, Sendable {
        /// Gain while ducked, 0.05–1 (default 0.3).
        public var level: Double?
        /// 0.05–2 (default 0.25).
        public var fadeSec: Double?
        /// Edit suite: ramp down before (0.05–2) and back up after (0.05–3); else fadeSec for both.
        public var attackSec: Double?
        public var releaseSec: Double?
        public var under: [DuckSource]
        public init(level: Double? = nil, fadeSec: Double? = nil, attackSec: Double? = nil, releaseSec: Double? = nil, under: [DuckSource]) {
            self.level = level; self.fadeSec = fadeSec; self.attackSec = attackSec; self.releaseSec = releaseSec; self.under = under
        }

    }

    public enum TrackKind: String, Codable, Hashable, Sendable, CaseIterable {
        case main, video, image, text, caption, music, voice, sfx
        /// Adjustment layers (contract, WS8 3e20288): their colour applies to the whole picture under text and captions.
        case adjust
        public var isAudio: Bool { self == .music || self == .voice || self == .sfx }
        public var isVideo: Bool { self == .main || self == .video }
    }

    /// An adjustment layer's item: colour (adjust, filter) and strength (opacity 0–1), keyframes on opacity and the colour
    /// properties. `strayKeys` names picture fields it was given (look, mask, …) so validation can refuse them.
    public struct AdjustItem: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var startSec: Double
        public var durationSec: Double
        public var adjust: Adjust?
        public var filter: FilterRef?
        public var keyframes: Keyframes?
        public var opacity: Double?
        public var strayKeys: [String] = []

        public init(id: String, startSec: Double, durationSec: Double, adjust: Adjust? = nil, filter: FilterRef? = nil, keyframes: Keyframes? = nil,
                    opacity: Double? = nil) {
            self.id = id; self.startSec = startSec; self.durationSec = durationSec; self.adjust = adjust; self.filter = filter
            self.keyframes = keyframes; self.opacity = opacity
        }

        enum CodingKeys: String, CodingKey { case id, startSec, durationSec, adjust, filter, keyframes, opacity }
        static let refused = ["look", "mask", "transform", "crop", "fit", "asset"]

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            startSec = try c.decode(Double.self, forKey: .startSec)
            durationSec = try c.decode(Double.self, forKey: .durationSec)
            adjust = try c.decodeIfPresent(Adjust.self, forKey: .adjust)
            filter = try c.decodeIfPresent(FilterRef.self, forKey: .filter)
            keyframes = try c.decodeIfPresent(Keyframes.self, forKey: .keyframes)
            opacity = try c.decodeIfPresent(Double.self, forKey: .opacity)
            let any = try decoder.container(keyedBy: AnyKey.self)
            strayKeys = Self.refused.filter { k in any.allKeys.contains { $0.stringValue == k } }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(startSec, forKey: .startSec)
            try c.encode(durationSec, forKey: .durationSec)
            try c.encodeIfPresent(adjust, forKey: .adjust)
            try c.encodeIfPresent(filter, forKey: .filter)
            try c.encodeIfPresent(keyframes, forKey: .keyframes)
            try c.encodeIfPresent(opacity, forKey: .opacity)
        }

        struct AnyKey: CodingKey {
            var stringValue: String; var intValue: Int?
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
        }

        public static func == (a: AdjustItem, b: AdjustItem) -> Bool {
            a.id == b.id && a.startSec == b.startSec && a.durationSec == b.durationSec && a.adjust == b.adjust && a.filter == b.filter
                && a.keyframes == b.keyframes && a.opacity == b.opacity && a.strayKeys == b.strayKeys
        }
    }

    /// An item of a track; which kind a track holds follows from the track's kind.
    public enum Item: Codable, Hashable, Sendable, Identifiable {
        case video(VideoClip)
        case image(ImageItem)
        case text(TextItem)
        case audio(AudioClip)
        case adjust(AdjustItem)

        public var id: String {
            get {
                switch self {
                case .video(let c): return c.id
                case .image(let c): return c.id
                case .text(let c): return c.id
                case .audio(let c): return c.id
                case .adjust(let c): return c.id
                }
            }
            set {
                switch self {
                case .video(var c): c.id = newValue; self = .video(c)
                case .image(var c): c.id = newValue; self = .image(c)
                case .text(var c): c.id = newValue; self = .text(c)
                case .audio(var c): c.id = newValue; self = .audio(c)
                case .adjust(var c): c.id = newValue; self = .adjust(c)
                }
            }
        }

        /// The item's timeline start on a non-main track (main clips have none: see EditV2.timeline).
        public var startSec: Double {
            get {
                switch self {
                case .video(let c): return c.startSec ?? 0
                case .image(let c): return c.startSec
                case .text(let c): return c.startSec
                case .audio(let c): return c.startSec
                case .adjust(let c): return c.startSec
                }
            }
            set {
                switch self {
                case .video(var c): c.startSec = newValue; self = .video(c)
                case .image(var c): c.startSec = newValue; self = .image(c)
                case .text(var c): c.startSec = newValue; self = .text(c)
                case .audio(var c): c.startSec = newValue; self = .audio(c)
                case .adjust(var c): c.startSec = newValue; self = .adjust(c)
                }
            }
        }

        /// Its own timeline length: (out − in) / speed for clips, durationSec for images and text.
        public var lengthSec: Double {
            switch self {
            case .video(let c): return EditV2.clipLength(c)
            case .image(let c): return c.durationSec
            case .text(let c): return c.durationSec
            case .audio(let c): return EditV2.clipLength(c)
            case .adjust(let c): return c.durationSec
            }
        }

        public var videoClip: VideoClip? { if case .video(let c) = self { return c }; return nil }
        public var imageItem: ImageItem? { if case .image(let c) = self { return c }; return nil }
        public var textItem: TextItem? { if case .text(let c) = self { return c }; return nil }
        public var audioClip: AudioClip? { if case .audio(let c) = self { return c }; return nil }
        public var adjustItem: AdjustItem? { if case .adjust(let c) = self { return c }; return nil }
        public var keyframes: Keyframes? {
            switch self {
            case .video(let c): return c.keyframes
            case .image(let c): return c.keyframes
            case .text(let c): return c.keyframes
            case .audio(let c): return c.keyframes
            case .adjust(let c): return c.keyframes
            }
        }

        /// Decoding without the track's kind (only used for items of a caption track, which should have none): by its keys.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: ProbeKeys.self)
            if c.contains(.text) { self = .text(try TextItem(from: decoder)) }
            else if c.contains(.inSec) { self = c.contains(.speed) && !c.contains(.startSec) ? .video(try VideoClip(from: decoder)) : .audio(try AudioClip(from: decoder)) }
            else { self = .image(try ImageItem(from: decoder)) }
        }
        private enum ProbeKeys: String, CodingKey { case text, inSec, speed, startSec }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .video(let c): try c.encode(to: encoder)
            case .image(let c): try c.encode(to: encoder)
            case .text(let c): try c.encode(to: encoder)
            case .audio(let c): try c.encode(to: encoder)
            case .adjust(let c): try c.encode(to: encoder)
            }
        }
    }

    public struct Track: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var kind: TrackKind
        public var name: String?
        public var muted: Bool?
        public var hidden: Bool?
        /// 0–2.
        public var volume: Double?
        public var items: [Item]
        /// Kind "caption" only.
        public var caption: CaptionTrack?
        /// Kind "music" only.
        public var duck: Duck?

        public init(id: String, kind: TrackKind, name: String? = nil, muted: Bool? = nil, hidden: Bool? = nil, volume: Double? = nil,
                    items: [Item] = [], caption: CaptionTrack? = nil, duck: Duck? = nil) {
            self.id = id; self.kind = kind; self.name = name; self.muted = muted; self.hidden = hidden; self.volume = volume
            self.items = items; self.caption = caption; self.duck = duck
        }

        enum CodingKeys: String, CodingKey { case id, kind, name, muted, hidden, volume, items, caption, duck }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(TrackKind.self, forKey: .kind)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            muted = try c.decodeIfPresent(Bool.self, forKey: .muted)
            hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
            volume = try c.decodeIfPresent(Double.self, forKey: .volume)
            caption = try c.decodeIfPresent(CaptionTrack.self, forKey: .caption)
            duck = try c.decodeIfPresent(Duck.self, forKey: .duck)
            var list: [Item] = []
            var u = try c.nestedUnkeyedContainer(forKey: .items)
            while !u.isAtEnd {
                switch kind {
                case .main, .video: list.append(.video(try u.decode(VideoClip.self)))
                case .image: list.append(.image(try u.decode(ImageItem.self)))
                case .text: list.append(.text(try u.decode(TextItem.self)))
                case .music, .voice, .sfx: list.append(.audio(try u.decode(AudioClip.self)))
                case .caption: list.append(try u.decode(Item.self))
                case .adjust: list.append(.adjust(try u.decode(AdjustItem.self)))
                }
            }
            items = list
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(muted, forKey: .muted)
            try c.encodeIfPresent(hidden, forKey: .hidden)
            try c.encodeIfPresent(volume, forKey: .volume)
            try c.encode(items, forKey: .items)
            try c.encodeIfPresent(caption, forKey: .caption)
            try c.encodeIfPresent(duck, forKey: .duck)
        }

        public func item(_ id: String) -> Item? { items.first { $0.id == id } }
    }

    public struct Canvas: Codable, Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var fps: Double
        /// "#RRGGBB", default black.
        public var background: String?
        /// Wave 1: the background colour (nil / color) or a blurred copy of the main clip (blur) behind contain-fitted clips.
        public var fill: CanvasFill?
        public init(width: Int, height: Int, fps: Double, background: String? = nil, fill: CanvasFill? = nil) {
            self.width = width; self.height = height; self.fps = fps; self.background = background; self.fill = fill
        }
    }

    /// The marker `sourceTakeId` of a blank project (server model.ts BLANK_SOURCE).
    public static let blankSourceId = "blank"

    public struct Project: Codable, Hashable, Sendable {
        public var version: Int
        public var sourceTakeId: String
        public var canvas: Canvas
        public var assets: [Asset]
        public var tracks: [Track]
        public var mute: Bool?
        public init(version: Int = 2, sourceTakeId: String, canvas: Canvas, assets: [Asset], tracks: [Track], mute: Bool? = nil) {
            self.version = version; self.sourceTakeId = sourceTakeId; self.canvas = canvas; self.assets = assets; self.tracks = tracks; self.mute = mute
        }

        /// "New blank project" (owner request 2026-11-11): no source take; `sourceTakeId` is `EditV2.blankSourceId` until the
        /// first save (POST /v1/edits makes it a new Library video). Empty until a clip is added (0 s; Export waits for a clip).
        public var isBlank: Bool { sourceTakeId == EditV2.blankSourceId }
        public static func blank(_ canvas: Canvas = Canvas(width: 1080, height: 1920, fps: 30, background: "#000000")) -> Project {
            Project(sourceTakeId: EditV2.blankSourceId, canvas: canvas, assets: [], tracks: [Track(id: "main", kind: .main)])
        }

        public func asset(_ id: String) -> Asset? { assets.first { $0.id == id } }
        public func track(_ id: String) -> Track? { tracks.first { $0.id == id } }
        public var mainTrack: Track? { tracks.first { $0.kind == .main } }
        public var mainClips: [VideoClip] { mainTrack?.items.compactMap(\.videoClip) ?? [] }
        public var captionTrack: CaptionTrack? { tracks.first { $0.kind == .caption && $0.caption != nil }?.caption }

        public static func decode(_ data: Data) throws -> Project { try JSONDecoder().decode(Project.self, from: data) }
        public func encoded() throws -> Data {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            return try e.encode(self)
        }
    }

    /// The v1 edit list as it is on the wire (`EditList` is the editor's working copy of the same thing).
    public struct V1Segment: Codable, Hashable, Sendable {
        public var inSec: Double
        public var outSec: Double
        public var speed: Double
        public var muted: Bool?
        public init(inSec: Double, outSec: Double, speed: Double, muted: Bool? = nil) {
            self.inSec = inSec; self.outSec = outSec; self.speed = speed; self.muted = muted
        }
    }

    public struct EditListV1: Codable, Hashable, Sendable {
        public var version: Int
        public var sourceTakeId: String
        public var sourceDurationSec: Double
        public var segments: [V1Segment]
        public var mute: Bool
        public init(sourceTakeId: String, sourceDurationSec: Double, segments: [V1Segment], mute: Bool) {
            version = 1; self.sourceTakeId = sourceTakeId; self.sourceDurationSec = sourceDurationSec; self.segments = segments; self.mute = mute
        }
        public init(_ l: EditList) {
            self.init(sourceTakeId: l.sourceTakeId, sourceDurationSec: l.sourceDurationSec,
                      segments: l.segments.map { V1Segment(inSec: $0.inSec, outSec: $0.outSec, speed: $0.speed, muted: $0.muted ? true : nil) }, mute: l.mute)
        }
        /// The editor's working copy.
        public var editList: EditList {
            EditList(sourceTakeId: sourceTakeId, sourceDurationSec: sourceDurationSec,
                     segments: segments.map { EditSegment(inSec: $0.inSec, outSec: $0.outSec, speed: $0.speed, muted: $0.muted ?? false) }, mute: mute)
        }
    }

    public struct SourceFacts: Codable, Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var fps: Double
        public var hasAudio: Bool?
        public init(width: Int, height: Int, fps: Double, hasAudio: Bool? = nil) { self.width = width; self.height = height; self.fps = fps; self.hasAudio = hasAudio }
    }

    /// A source time range (silence/filler cuts, ducking regions).
    public struct SecRange: Codable, Hashable, Sendable {
        public var startSec: Double
        public var endSec: Double
        public init(startSec: Double, endSec: Double) { self.startSec = startSec; self.endSec = endSec }
    }
}
