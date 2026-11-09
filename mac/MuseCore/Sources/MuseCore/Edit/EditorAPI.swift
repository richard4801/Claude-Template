import Foundation

// Edit suite (workstream 3): the Editor v2 API types (plans/api.md "Editor v2"): AI helper jobs (captions, cuts incl. the
// free silence-only pass, background removal, voice clean-up, free beat detection), estimates, editor uploads (music,
// voice-overs, .cube files) and versions saved with a v2 project. Nothing here names a provider or model.

public enum EditorJobKind: String, Codable, Hashable, Sendable, CaseIterable {
    case captions, cuts, matte, denoise, beats
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
    public init(language: String? = nil, minSilenceSec: Double? = nil, keepPadSec: Double? = nil, fillers: Bool? = nil, repeats: Bool? = nil,
                extraFillers: [String]? = nil, fromJobId: String? = nil, silenceOnly: Bool? = nil, noiseDb: Double? = nil, analyzeOnly: Bool? = nil,
                points: [KeepPoint]? = nil) {
        self.points = points
        self.language = language; self.minSilenceSec = minSilenceSec; self.keepPadSec = keepPadSec; self.fillers = fillers; self.repeats = repeats
        self.extraFillers = extraFillers; self.fromJobId = fromJobId; self.silenceOnly = silenceOnly; self.noiseDb = noiseDb; self.analyzeOnly = analyzeOnly
    }
}

public struct EditorJobRequest: Codable, Hashable, Sendable {
    public var kind: EditorJobKind
    public var source: EditorSource
    public var options: EditorJobOptions?
    /// Owner only (WS13): the helper's model, checked by the server against its candidates; nil = the studio's default.
    public var engineModel: String?
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
        case .denoise: return .denoise
        case .beats: return nil
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
    public init(paid: Helper? = nil, captions: Helper? = nil, matte: Helper? = nil, denoise: Helper? = nil) {
        self.paid = paid; self.captions = captions; self.matte = matte; self.denoise = denoise
    }
    /// Background removal (and tap to keep) can run.
    public var matteAvailable: Bool { isAvailable(.matte) }

    private func helper(_ k: EditorJobKind) -> Helper? {
        switch k {
        case .captions: return captions
        case .matte: return matte
        case .denoise: return denoise
        case .cuts, .beats: return nil   // the free passes are always offered
        }
    }
    private var paidOn: Bool { paid?.available != false }
    public func isAvailable(_ k: EditorJobKind) -> Bool {
        guard let h = helper(k) else { return true }
        return h.available != false && (paidOn || k == .cuts || k == .beats)
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
public struct EditorResultAsset: Codable, Hashable, Sendable {
    public var kind: String
    public var upload: String?
    public var take: String?
    public var url: String?
    public var durationSec: Double?
    public init(kind: String, upload: String? = nil, take: String? = nil, url: String? = nil, durationSec: Double? = nil) {
        self.kind = kind; self.upload = upload; self.take = take; self.url = url; self.durationSec = durationSec
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
    public var points: [KeepPoint]?
    public var suggestion: DenoiseSuggestion?
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
