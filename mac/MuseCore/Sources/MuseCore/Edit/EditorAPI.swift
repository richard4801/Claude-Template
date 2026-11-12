import Foundation

// Edit suite (workstream 3): the Editor v2 API types (plans/api.md "Editor v2"): AI helper jobs (captions, cuts incl. the
// free silence-only pass, background removal, voice clean-up, free beat detection), estimates, editor uploads (music,
// voice-overs, .cube files) and versions saved with a v2 project. Nothing here names a provider or model.

public enum EditorJobKind: String, Codable, Hashable, Sendable, CaseIterable {
    case captions, cuts, matte, denoise, beats
    /// Reverse (WS8 cb5413e): a reversed copy of the whole source (≤ 60 s), local and free.
    case reverse
    /// Stabilise (XL, WS16 d206d37): a steadied copy of the whole source (≤ 3 min), the same length and timing; free.
    case stabilize
    /// Smooth slow motion (XL, WS16 402c87d5): a source range with frames interpolated, factor× as long, silent; paid.
    case slowmo
    /// Translated captions (XL, WS16 8e126801 / e1e3dd4f): the caption lines in another language, timed per line; paid.
    case translate
    /// Split voice and music (WS16 d180db0e): vocals and instrumental as two audio uploads; paid.
    case separate
    /// Cut out a picture (WS16 b1fa8715): the person, or what the taps pick, as a trimmed PNG; paid.
    case cutout
    /// Layers (plans/layers-edit.md): up to 5 tapped or boxed things followed through a main clip (≤ 60 s), one matte each.
    case layers
}

/// The media a job works on: a video take of the studio, or an upload of the studio (+ its length).
public struct EditorSource: Codable, Hashable, Sendable {
    public var takeId: String?
    public var uploadId: String?
    public var durationSec: Double?
    public init(takeId: String? = nil, uploadId: String? = nil, durationSec: Double? = nil) {
        self.takeId = takeId; self.uploadId = uploadId; self.durationSec = durationSec
    }
    /// The source of an asset of a project (its take, or its upload with the asset's length); nil for bundled media.
    public init?(_ a: EditV2.Asset) {
        if let t = a.take { self.init(takeId: t) }
        else if let u = a.upload { self.init(uploadId: u, durationSec: a.durationSec) }
        else { return nil }
    }
}

/// Tap to keep (background removal of one subject): a point on the frame, 0–1 from the top left, at `t` seconds of the source;
/// `keep` false = leave this out. 1–10 per job, at least one kept (plans/api.md "KeepPoint").
public struct KeepPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var t: Double?
    public var keep: Bool?
    public init(x: Double, y: Double, t: Double? = nil, keep: Bool? = nil) { self.x = x; self.y = y; self.t = t; self.keep = keep }
    public var keeps: Bool { keep != false }
}

public struct EditorJobOptions: Codable, Hashable, Sendable {
    public var language: String?
    public var minSilenceSec: Double?
    public var keepPadSec: Double?
    public var fillers: Bool?
    public var repeats: Bool?
    public var extraFillers: [String]?
    public var fromJobId: String?
    public var silenceOnly: Bool?
    public var noiseDb: Double?
    public var analyzeOnly: Bool?
    /// matte: tap to keep.
    public var points: [KeepPoint]?
    /// layers: the things to find, each named and tapped or boxed.
    public var objects: [LayerObject]?
    /// slowmo: 2 or 4, and the source range (0.3–10 s).
    public var factor: Double?
    public var startSec: Double?
    public var endSec: Double?
    /// translate: the target (and source) language codes, "standard" | "best", and the caption lines as shown.
    public var targetLanguage: String?
    public var sourceLanguage: String?
    public var quality: String?
    public var lines: [TranslateLine]?
    public init(language: String? = nil, minSilenceSec: Double? = nil, keepPadSec: Double? = nil, fillers: Bool? = nil, repeats: Bool? = nil,
                extraFillers: [String]? = nil, fromJobId: String? = nil, silenceOnly: Bool? = nil, noiseDb: Double? = nil, analyzeOnly: Bool? = nil,
                points: [KeepPoint]? = nil) {
        self.points = points
        self.language = language; self.minSilenceSec = minSilenceSec; self.keepPadSec = keepPadSec; self.fillers = fillers; self.repeats = repeats
        self.extraFillers = extraFillers; self.fromJobId = fromJobId; self.silenceOnly = silenceOnly; self.noiseDb = noiseDb; self.analyzeOnly = analyzeOnly
    }
}

/// A caption line sent to translate (as shown, edits included) or returned translated.
public struct TranslateLine: Codable, Hashable, Sendable {
    public var id: String?
    public var text: String
    public var startSec: Double
    public var endSec: Double
    public var translated: String?
    public init(id: String? = nil, text: String, startSec: Double, endSec: Double, translated: String? = nil) {
        self.id = id; self.text = text; self.startSec = startSec; self.endSec = endSec; self.translated = translated
    }
}

public struct EditorJobRequest: Codable, Hashable, Sendable {
    public var kind: EditorJobKind
    public var source: EditorSource
    public var options: EditorJobOptions?
    /// Owner only (WS13): the helper's model, checked by the server against its candidates; nil = the studio's default.
    public var engineModel: String?
    /// layers: the price the owner accepted (a run above $1 needs it; the server answers 409 price_confirm otherwise).
    public var acceptUsd: Double?
    public init(kind: EditorJobKind, source: EditorSource, options: EditorJobOptions? = nil, engineModel: String? = nil) {
        self.kind = kind; self.source = source; self.options = options; self.engineModel = engineModel
    }
}

extension EditorJobKind {
    /// The model purpose behind a helper (server editor/service.ts): captions and cuts transcribe, matte cuts out (track
    /// when it follows picked points), denoise separates; beats run no model.
    public func enginePurpose(_ options: EditorJobOptions?) -> EnginePurpose? {
        switch self {
        case .captions, .cuts: return .captions
        case .matte: return options?.points != nil ? .track : .matte
        case .layers: return .track
        case .denoise: return .denoise
        case .beats, .reverse, .stabilize, .slowmo, .translate, .separate, .cutout: return nil
        }
    }
}

/// GET /v1/editor/features: what the server can do now (paid helpers switched off by the owner, background removal not
/// ready yet). Only what the suite reads is decoded; a missing entry means available, so an older server offers everything.
public struct EditorFeatures: Codable, Hashable, Sendable {
    public struct Helper: Codable, Hashable, Sendable {
        public var available: Bool?
        /// Plain words for why it isn't available ("AI editing helpers are switched off for now").
        public var reason: String?
        public var maxSec: Double?
        public init(available: Bool? = nil, reason: String? = nil, maxSec: Double? = nil) { self.available = available; self.reason = reason; self.maxSec = maxSec }
    }
    public typealias Matte = Helper
    /// All paid helpers at once (the owner's switch).
    public var paid: Helper?
    public var captions: Helper?
    public var matte: Helper?
    public var denoise: Helper?
    /// Stabilise (free, up to `maxSec`).
    public var stabilize: Helper?
    /// Smooth slow motion (paid; `factors`, `maxRangeSec`).
    public var slowmo: Slowmo?
    /// Translated captions (paid): the languages offered (code → name), the qualities, the most words.
    public var translate: Translate?
    /// Split voice and music, and cut out a picture (paid).
    public var separate: Helper?
    public var cutout: Helper?
    /// Layers (paid, clips up to `maxSec`).
    public var layers: Helper?
    public struct Translate: Codable, Hashable, Sendable {
        public var available: Bool?
        public var reason: String?
        public var languages: [String: String]?
        public var qualities: [String]?
        public var maxWords: Double?
        public init(available: Bool? = nil, reason: String? = nil, languages: [String: String]? = nil, qualities: [String]? = nil, maxWords: Double? = nil) {
            self.available = available; self.reason = reason; self.languages = languages; self.qualities = qualities; self.maxWords = maxWords
        }
    }
    public struct Slowmo: Codable, Hashable, Sendable {
        public var available: Bool?
        public var reason: String?
        public var factors: [Double]?
        public var maxRangeSec: Double?
        public init(available: Bool? = nil, reason: String? = nil, factors: [Double]? = nil, maxRangeSec: Double? = nil) {
            self.available = available; self.reason = reason; self.factors = factors; self.maxRangeSec = maxRangeSec
        }
    }
    public init(paid: Helper? = nil, captions: Helper? = nil, matte: Helper? = nil, denoise: Helper? = nil, stabilize: Helper? = nil, slowmo: Slowmo? = nil) {
        self.paid = paid; self.captions = captions; self.matte = matte; self.denoise = denoise; self.stabilize = stabilize; self.slowmo = slowmo
    }
    /// Background removal (and tap to keep) can run.
    public var matteAvailable: Bool { isAvailable(.matte) }

    private func helper(_ k: EditorJobKind) -> Helper? {
        switch k {
        case .captions: return captions
        case .matte: return matte
        case .denoise: return denoise
        case .stabilize: return stabilize
        case .separate: return separate
        case .cutout: return cutout
        case .layers: return layers
        case .translate: return translate.map { Helper(available: $0.available, reason: $0.reason) }
        case .slowmo: return slowmo.map { Helper(available: $0.available, reason: $0.reason, maxSec: $0.maxRangeSec) }
        case .cuts, .beats, .reverse: return nil   // the free passes are always offered
        }
    }
    private var paidOn: Bool { paid?.available != false }
    public func isAvailable(_ k: EditorJobKind) -> Bool {
        guard let h = helper(k) else { return true }
        return h.available != false && (paidOn || k == .cuts || k == .beats || k == .reverse || k == .stabilize)
    }
    /// Why a helper can't run, in plain words: the owner's switch, else "Coming soon" (background removal not ready yet).
    public func note(_ k: EditorJobKind) -> String? {
        guard !isAvailable(k) else { return nil }
        if !paidOn { return paid?.reason ?? helper(k)?.reason ?? "AI editing helpers are switched off for now" }
        return helper(k)?.reason ?? "Coming soon"
    }
}

/// POST /v1/editor/estimate.
public struct EditorEstimate: Codable, Hashable, Sendable {
    public var kind: EditorJobKind
    public var usd: Double
    public var tokens: Double?
    public var free: Bool
    public var reusesTranscript: Bool?
    public var durationSec: Double?
    public init(kind: EditorJobKind, usd: Double, tokens: Double? = nil, free: Bool, reusesTranscript: Bool? = nil, durationSec: Double? = nil) {
        self.kind = kind; self.usd = usd; self.tokens = tokens; self.free = free; self.reusesTranscript = reusesTranscript; self.durationSec = durationSec
    }

    /// "Free" or "≈ $0.04" — how the suite shows an AI helper's price.
    public var label: String { EditorEstimate.label(free: free, usd: usd) }
    public static func label(free: Bool, usd: Double) -> String {
        if free || usd <= 0 { return "Free" }
        return "≈ $" + String(format: "%.2f", usd)
    }
}

/// A media asset a job made (the cut-out person, the voice alone).
/// A thing to find (layers): a name, taps (KeepPoint) and/or a box, all 0–1 of the frame at `t` seconds of the source.
public struct LayerObject: Codable, Hashable, Sendable {
    public struct Box: Codable, Hashable, Sendable {
        public var x: Double, y: Double, w: Double, h: Double, t: Double?
        public init(x: Double, y: Double, w: Double, h: Double, t: Double? = nil) { self.x = x; self.y = y; self.w = w; self.h = h; self.t = t }
    }
    public var name: String
    public var points: [KeepPoint]?
    public var box: Box?
    public init(name: String, points: [KeepPoint]? = nil, box: Box? = nil) { self.name = name; self.points = points; self.box = box }
}
/// One layer a layers job found.
public struct LayerResult: Codable, Hashable, Sendable {
    public var name: String
    public var asset: EditorResultAsset
    public var track: EditV2.LayerTrack?
    public init(name: String, asset: EditorResultAsset, track: EditV2.LayerTrack? = nil) { self.name = name; self.asset = asset; self.track = track }
}

public struct EditorResultAsset: Codable, Hashable, Sendable {
    public var kind: String
    public var upload: String?
    public var take: String?
    public var url: String?
    public var durationSec: Double?
    /// cutout: the PNG's size.
    public var width: Int?
    public var height: Int?
    public init(kind: String, upload: String? = nil, take: String? = nil, url: String? = nil, durationSec: Double? = nil, width: Int? = nil, height: Int? = nil) {
        self.kind = kind; self.upload = upload; self.take = take; self.url = url; self.durationSec = durationSec; self.width = width; self.height = height
    }
}

public struct DenoiseSuggestion: Codable, Hashable, Sendable {
    /// none | light | strong
    public var level: String
    public var reason: String?
    public var confidence: Double?
    public init(level: String, reason: String? = nil, confidence: Double? = nil) { self.level = level; self.reason = reason; self.confidence = confidence }
}

/// The union of the job results (each kind fills its own fields).
public struct EditorJobResult: Codable, Hashable, Sendable {
    // captions / cuts
    public var language: String?
    public var words: [EditV2.Word]?
    public var reused: Bool?
    public var cuts: [EditV2.Cut]?
    public var savedSec: Double?
    // matte / denoise
    public var asset: EditorResultAsset?
    /// Older matte results: the person on green, keyed out with `chroma`.
    public var chroma: EditV2.Chroma?
    /// matte (2026-11-08): `asset` is an alpha matte (grey, white = keep) for `alphaMatte` on the original clip.
    public var alpha: Bool?
    /// "person" | "tracked" (tap to keep)
    public var mode: String?
    /// separate: the two parts.
    public var vocals: EditorResultAsset?
    public var instrumental: EditorResultAsset?
    /// cutout: where the cut-out sits in the source picture (pixels), and the source's size.
    public var box: EditV2.CutoutBox?
    public var sourceWidth: Double?
    public var sourceHeight: Double?
    public var points: [KeepPoint]?
    /// layers: one matte per thing found, with where it is over time.
    public var layers: [LayerResult]?
    public var suggestion: DenoiseSuggestion?
    // translate: the source language, the lines as translated, how many stayed as they were, the quality used
    public var sourceLanguage: String?
    public var lines: [TranslateLine]?
    public var untranslatedLines: Int?
    /// captions / translate: a note about the export (a script the server's export can't draw yet), shown with the captions.
    public var exportNotice: String?
    public var quality: String?
    // slowmo: the factor and source range the copy was made from, and its frame rate
    public var factor: Double?
    public var startSec: Double?
    public var endSec: Double?
    public var fps: Double?
    // reverse: the reversed copy's picture size and sound
    public var width: Int?
    public var height: Int?
    public var hasAudio: Bool?
    // beats
    public var bpm: Double?
    public var beats: [Double]?
    public var strong: [Double]?
    public var durationSec: Double?
    public init(language: String? = nil, words: [EditV2.Word]? = nil, reused: Bool? = nil, cuts: [EditV2.Cut]? = nil, savedSec: Double? = nil,
                asset: EditorResultAsset? = nil, chroma: EditV2.Chroma? = nil, suggestion: DenoiseSuggestion? = nil, bpm: Double? = nil,
                beats: [Double]? = nil, strong: [Double]? = nil, durationSec: Double? = nil) {
        self.language = language; self.words = words; self.reused = reused; self.cuts = cuts; self.savedSec = savedSec; self.asset = asset
        self.chroma = chroma; self.suggestion = suggestion; self.bpm = bpm; self.beats = beats; self.strong = strong; self.durationSec = durationSec
    }
}

public struct EditorJob: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: EditorJobKind
    /// running | done | failed | cancelled
    public var state: String
    public var progress: Double
    public var phase: String?
    public var estimateUsd: Double?
    public var costUsd: Double?
    public var result: EditorJobResult?
    public var error: String?
    public init(id: String, kind: EditorJobKind, state: String, progress: Double = 0, phase: String? = nil, estimateUsd: Double? = nil,
                costUsd: Double? = nil, result: EditorJobResult? = nil, error: String? = nil) {
        self.id = id; self.kind = kind; self.state = state; self.progress = progress; self.phase = phase; self.estimateUsd = estimateUsd
        self.costUsd = costUsd; self.result = result; self.error = error
    }
    public var isRunning: Bool { state == "running" }
    public var isDone: Bool { state == "done" }
    public var isOver: Bool { state != "running" }

    enum CodingKeys: String, CodingKey { case id, kind, state, progress, phase, estimateUsd, costUsd, result, error }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(EditorJobKind.self, forKey: .kind)
        state = (try? c.decode(String.self, forKey: .state)) ?? "running"
        progress = (try? c.decode(Double.self, forKey: .progress)) ?? 0
        phase = try? c.decodeIfPresent(String.self, forKey: .phase)
        estimateUsd = try? c.decodeIfPresent(Double.self, forKey: .estimateUsd)
        costUsd = try? c.decodeIfPresent(Double.self, forKey: .costUsd)
        result = try? c.decodeIfPresent(EditorJobResult.self, forKey: .result)
        // `error` may be a string or an object with a message.
        if let s = try? c.decodeIfPresent(String.self, forKey: .error) { error = s }
        else if let o = try? c.decodeIfPresent([String: String].self, forKey: .error) { error = o["message"] ?? o["error"] }
        else { error = nil }
    }
}

/// POST /v1/editor/luts/validate.
/// POST /v1/editor/uploads/font-check: the upload is a .ttf / .otf, and its display name.
public struct FontCheck: Codable, Hashable, Sendable {
    public var uploadId: String
    public var name: String
    public init(uploadId: String, name: String) { self.uploadId = uploadId; self.name = name }
}

public struct LutValidation: Codable, Hashable, Sendable {
    public var uploadId: String
    public var size: Int
    public var title: String?
    public init(uploadId: String, size: Int, title: String? = nil) { self.uploadId = uploadId; self.size = size; self.title = title }
}

/// POST /v1/takes/{id}/versions with a v2 project (`edits.version: 2`).
public struct TakeVersionV2Request: Codable, Sendable, Equatable {
    public var uploadId: String
    public var thumbUploadId: String?
    public var thumb: ImageRef?
    public var edits: EditV2.Project
    public var durationSec: Double
    public var width: Int
    public var height: Int
    public var fps: Double?
    /// The version's name (1–80 characters after trimming; Claude's `save_version` name). Left out when empty.
    public var name: String?
    /// The export sheet's "Label as AI-generated" (sent only when on; the server stores it on the version).
    public var aiLabel: Bool?
    public init(uploadId: String, thumbUploadId: String? = nil, thumb: ImageRef? = nil, edits: EditV2.Project, durationSec: Double, width: Int, height: Int,
                fps: Double? = nil, name: String? = nil, aiLabel: Bool = false) {
        self.uploadId = uploadId; self.thumbUploadId = thumbUploadId; self.thumb = thumb; self.edits = edits; self.durationSec = durationSec
        self.width = width; self.height = height; self.fps = fps; self.name = TakeVersionV2Request.versionName(name)
        self.aiLabel = aiLabel ? true : nil
    }

    public static func make(_ upload: EditedUpload, video: EditedVideo, edits: EditV2.Project, name: String? = nil, aiLabel: Bool = false) -> TakeVersionV2Request {
        TakeVersionV2Request(uploadId: upload.uploadId, thumbUploadId: upload.thumbUploadId, thumb: upload.thumbUploadId == nil ? upload.thumb : nil,
                             edits: edits, durationSec: (video.durationSec * 1000).rounded() / 1000, width: video.width, height: video.height,
                             fps: video.fps.map { ($0 * 100).rounded() / 100 }, name: name, aiLabel: aiLabel)
    }

    /// The server's rule for a version name: trimmed, 1–80 characters (longer is cut at 80), nil when empty.
    public static func versionName(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The server's rule: the file's length within max(0.5 s, 5 %) of the project's.
    public static func accepts(project: EditV2.Project, durationSec: Double) -> Bool {
        let d = EditV2.durationSec(project)
        return abs(durationSec - d) <= max(0.5, 0.05 * d)
    }
}

/// A saved style kit (GET/POST/PATCH /v1/editor/kits, plans/api.md "Edit style kits"): members see their own, the owner
/// the studio's.
public struct EditKit: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kit: EditV2.StyleKit
    public var createdBy: String?
    public var createdAt: String?
    public var updatedAt: String?
    public init(id: String, name: String, kit: EditV2.StyleKit, createdBy: String? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.name = name; self.kit = kit; self.createdBy = createdBy; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct EditKitList: Codable, Hashable, Sendable { public var kits: [EditKit] }
public struct EditKitBody: Codable, Hashable, Sendable {
    public var name: String?
    public var kit: EditV2.StyleKit?
    public init(name: String? = nil, kit: EditV2.StyleKit? = nil) { self.name = name; self.kit = kit }
}
