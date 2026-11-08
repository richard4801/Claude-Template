import Foundation

/// "Recreate this edit" (plans/recreate-edit.md, plans/api.md "Recreate this edit"): a reference video the studio loved,
/// analysed into an edit recipe (schema `muse.recipe/1`, built by workstream 1). Every field the server may leave out is
/// optional and decoded leniently, so a newer server with extra or missing fields never breaks the Recipe view.
public enum Recreate {}

/// `GET /v1/recreate/references/{id}`: the reference, its analysis state and, when ready, its recipe.
public struct RecreateReference: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    /// analyzing | ready | failed
    public var state: String
    /// 0–100.
    public var progress: Double?
    public var phase: String?
    public var error: String?
    public var durationSec: Double?
    public var keep: Bool?
    public var createdAt: Int64?
    public var expiresAt: Int64?
    /// Authenticated routes (the reference stays private): load with the session token.
    public var videoUrl: String?
    public var posterUrl: String?
    public var recipe: Recipe?
    /// "file" | "link" (plans/api.md "From a link").
    public var source: String?
    /// The public link the video was fetched from.
    public var sourceUrl: String?
    /// Why it failed, as a code (`link_blocked` when the link's download was blocked).
    public var errorCode: String?
    /// The same link again: the member's reference made before (nothing is fetched twice).
    public var cached: Bool?
    /// A "Use this sound" reminder the server may add later, read leniently from `soundReminder` or `useThisSound`.
    public var soundReminder: String?

    public var isAnalyzing: Bool { state == "analyzing" }
    public var isReady: Bool { state == "ready" && recipe != nil }
    public var isFailed: Bool { state == "failed" }
    public var isLink: Bool { source == "link" || (source == nil && sourceUrl != nil) }
    /// Failed because the link couldn't be fetched: the page offers the file drop instead.
    public var failedFetchingLink: Bool { isFailed && RecreateLinks.offersFile(errorCode) }

    enum CodingKeys: String, CodingKey {
        case id, name, state, progress, phase, error, durationSec, keep, createdAt, expiresAt, videoUrl, posterUrl, recipe
        case source, sourceUrl, errorCode, cached, soundReminder, useThisSound
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(progress, forKey: .progress)
        try c.encodeIfPresent(phase, forKey: .phase)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(durationSec, forKey: .durationSec)
        try c.encodeIfPresent(keep, forKey: .keep)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(videoUrl, forKey: .videoUrl)
        try c.encodeIfPresent(posterUrl, forKey: .posterUrl)
        try c.encodeIfPresent(recipe, forKey: .recipe)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(sourceUrl, forKey: .sourceUrl)
        try c.encodeIfPresent(errorCode, forKey: .errorCode)
        try c.encodeIfPresent(cached, forKey: .cached)
        try c.encodeIfPresent(soundReminder, forKey: .soundReminder)
    }

    /// `useThisSound` as a string, or an object with `reminder`, `text` or `label`.
    static func reminderText(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s.isEmpty ? nil : s
        case .object(let o):
            for k in ["reminder", "text", "label"] { if case .string(let s)? = o[k], !s.isEmpty { return s } }
            return nil
        default: return nil
        }
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.o(.name)
        state = c.o(.state) ?? "analyzing"
        progress = c.o(.progress)
        phase = c.o(.phase)
        error = c.o(.error)
        durationSec = c.o(.durationSec)
        keep = c.o(.keep)
        createdAt = c.o(.createdAt)
        expiresAt = c.o(.expiresAt)
        videoUrl = c.o(.videoUrl)
        posterUrl = c.o(.posterUrl)
        recipe = c.o(.recipe)
        source = c.o(.source)
        sourceUrl = c.o(.sourceUrl)
        errorCode = c.o(.errorCode)
        cached = c.o(.cached)
        if let s: String = c.o(.soundReminder), !s.isEmpty {
            soundReminder = s
        } else if let v: JSONValue = c.o(.useThisSound) {
            soundReminder = Self.reminderText(v)
        }
    }
}

/// The edit recipe: what the reference does, shot by shot.
public struct Recipe: Codable, Hashable, Sendable {
    public var schema: String?
    public var id: String?
    public var referenceId: String?
    public var summary: String?
    public var tags: [String]
    public var source: Source?
    public var sound: Sound?
    public var pacing: Pacing?
    public var slots: [Slot]
    public var transitions: [Transition]
    public var text: [TextItem]
    public var grade: Grade?
    public var contactSheet: ContactSheet?
    public var gaps: [Gap]

    public struct Source: Codable, Hashable, Sendable {
        public var durationSec: Double?
        public var width: Int?
        public var height: Int?
        public var fps: Double?
        public var aspect: String?
        public var hasAudio: Bool?
    }

    public struct Sound: Codable, Hashable, Sendable {
        public var bpm: Double?
        public var beats: [Double]
        public var strong: [Double]
        public var confidence: Double?

        enum CodingKeys: String, CodingKey { case bpm, beats, strong, confidence }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            bpm = c.o(.bpm)
            beats = c.o(.beats) ?? []
            strong = c.o(.strong) ?? []
            confidence = c.o(.confidence)
        }
    }

    public struct Pacing: Codable, Hashable, Sendable {
        public struct Energy: Codable, Hashable, Sendable {
            public var everySec: Double?
            public var values: [Double]?
        }
        public var shots: Int?
        public var avgShotSec: Double?
        public var cutsPerMin: Double?
        public var energy: Energy?
    }

    /// One shot of the reference, and what it takes to make it with our content.
    public struct Slot: Codable, Hashable, Sendable, Identifiable {
        public struct Brief: Codable, Hashable, Sendable {
            public var shotSize: String?
            public var angle: String?
            public var subject: String?
            public var action: String?
            public var location: String?
            public var notes: String?
        }
        public struct CameraKey: Codable, Hashable, Sendable {
            public var t: Double
            public var x: Double?
            public var y: Double?
            public var scale: Double?
        }
        public struct Camera: Codable, Hashable, Sendable {
            /// static | pan | tilt | zoom_in | zoom_out | shake | mixed
            public var motion: String?
            public var shake: Double?
            public var keys: [CameraKey]?
            public var confidence: Double?
        }
        public struct SpeedPoint: Codable, Hashable, Sendable {
            public var t: Double
            public var speed: Double
        }
        public struct Speed: Codable, Hashable, Sendable {
            /// none | speed_up | slow_down | freeze | mixed
            public var ramp: String?
            public var curve: [SpeedPoint]?
            public var confidence: Double?
        }
        public struct Peak: Codable, Hashable, Sendable {
            public var t: Double
            public var strength: Double?
        }
        public struct Keypoint: Codable, Hashable, Sendable {
            public var name: String
            public var x: Double
            public var y: Double
            public var score: Double?
        }
        public struct Pose: Codable, Hashable, Sendable {
            /// pending | done | none
            public var status: String?
            public var frameSec: Double?
            public var keypoints: [Keypoint]?
        }

        public var id: String
        public var index: Int?
        public var startSec: Double
        public var endSec: Double
        public var durationSec: Double?
        public var keyframeSec: Double?
        public var confidence: Double?
        public var brief: Brief?
        public var rig: SuiteRig?
        public var camera: Camera?
        public var speed: Speed?
        public var peaks: [Peak]
        public var pose: Pose?
        /// Authenticated: the frame at `keyframeSec`, cut from the contact sheet.
        public var thumbUrl: String?

        public var length: Double { durationSec ?? max(0, endSec - startSec) }

        enum CodingKeys: String, CodingKey { case id, index, startSec, endSec, durationSec, keyframeSec, confidence, brief, rig, camera, speed, peaks, pose, thumbUrl }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            index = c.o(.index)
            startSec = c.o(.startSec) ?? 0
            endSec = c.o(.endSec) ?? 0
            durationSec = c.o(.durationSec)
            keyframeSec = c.o(.keyframeSec)
            confidence = c.o(.confidence)
            brief = c.o(.brief)
            rig = c.o(.rig)
            camera = c.o(.camera)
            speed = c.o(.speed)
            peaks = c.o(.peaks) ?? []
            pose = c.o(.pose)
            thumbUrl = c.o(.thumbUrl)
        }
    }

    public struct Transition: Codable, Hashable, Sendable {
        public var atSec: Double
        /// cut | flash | whip | zoom | fade | crossfade | glitch | unknown
        public var kind: String
        public var durationSec: Double?
        public var confidence: Double?
        public var from: String?
        public var to: String?
    }

    public struct TextItem: Codable, Hashable, Sendable, Identifiable {
        public struct Box: Codable, Hashable, Sendable {
            public var x: Double
            public var y: Double
            public var w: Double
            public var h: Double
        }
        public var id: String
        public var startSec: Double
        public var endSec: Double
        public var box: Box?
        /// Read by OCR when confident; nil when not read (a "text:words" gap says so).
        public var words: String?
        public var sizeFrac: Double?
        public var color: String?
        /// The nearest editor family: sans | serif | rounded | condensed | mono | marker.
        public var fontId: String?
        public var animIn: String?
        public var animOut: String?
        public var confidence: Double?
    }

    public struct Grade: Codable, Hashable, Sendable {
        public struct Look: Codable, Hashable, Sendable {
            public var id: String
            public var kind: String?
            public var label: String?
            public var distance: Double?
        }
        public var swatches: [String]?
        public var contrast: Double?
        public var saturation: Double?
        /// −1 (cool) … 1 (warm).
        public var warmth: Double?
        public var look: Look?
        public var confidence: Double?
    }

    public struct ContactSheet: Codable, Hashable, Sendable {
        public struct Tile: Codable, Hashable, Sendable {
            public var slotId: String
            public var x: Double
            public var y: Double
            public var w: Double
            public var h: Double
        }
        public var url: String?
        public var times: [Double]?
        public var tiles: [Tile]?
    }

    /// Something the editor can't do yet (an unknown transition, unread words), shown as "Not supported yet".
    public struct Gap: Codable, Hashable, Sendable {
        public var key: String?
        public var what: String
        public var atSec: Double?
        public var note: String?
    }

    enum CodingKeys: String, CodingKey { case schema, id, referenceId, summary, tags, source, sound, pacing, slots, transitions, text, grade, contactSheet, gaps }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schema = c.o(.schema)
        id = c.o(.id)
        referenceId = c.o(.referenceId)
        summary = c.o(.summary)
        tags = c.o(.tags) ?? []
        source = c.o(.source)
        sound = c.o(.sound)
        pacing = c.o(.pacing)
        slots = c.o(.slots) ?? []
        transitions = c.o(.transitions) ?? []
        text = c.o(.text) ?? []
        grade = c.o(.grade)
        contactSheet = c.o(.contactSheet)
        gaps = c.o(.gaps) ?? []
    }

    public var durationSec: Double { source?.durationSec ?? slots.map(\.endSec).max() ?? 0 }
}

/// `GET /v1/recreate/references/{id}/fill`: how each slot will be made (the slot matcher), and the match after apply.
public struct RecreateFill: Codable, Hashable, Sendable {
    public struct SlotFill: Codable, Hashable, Sendable, Identifiable {
        public struct Estimate: Codable, Hashable, Sendable {
            public var amount: Double
            public var label: String?
        }
        public var slotId: String
        /// empty | matched | to_generate | generating | ready
        public var state: String
        public var takeId: String?
        public var jobId: String?
        public var score: Double?
        public var estimate: Estimate?
        /// Claude's one line on the choice, in plain words.
        public var reason: String?
        /// swap (the model put into the reference's own shot) | generate (a new shot).
        public var method: String?
        /// "generate" after a swap that failed (refunded): offer generate, priced on its own.
        public var fallback: String?
        public var failedJobId: String?
        public var id: String { slotId }

        enum CodingKeys: String, CodingKey { case slotId, state, takeId, jobId, score, estimate, reason, method, fallback, failedJobId }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            slotId = try c.decode(String.self, forKey: .slotId)
            state = c.o(.state) ?? "empty"
            takeId = c.o(.takeId)
            jobId = c.o(.jobId)
            score = c.o(.score)
            estimate = c.o(.estimate)
            reason = c.o(.reason)
            method = c.o(.method)
            fallback = c.o(.fallback)
            failedJobId = c.o(.failedJobId)
        }
    }

    /// `applied.baked`: slots whose swapped shot already carries the reference's camera, speed and look.
    public var baked: [String: [String]] {
        guard case .object(let o)? = applied, case .object(let b)? = o["baked"] else { return [:] }
        var out: [String: [String]] = [:]
        for (k, v) in b {
            if case .array(let a) = v { out[k] = a.compactMap { if case .string(let s) = $0 { return s }; return nil } }
        }
        return out
    }
    public var referenceId: String
    public var slots: [SlotFill]
    public var applied: JSONValue?
    public var match: RecreateMatch?

    enum CodingKeys: String, CodingKey { case referenceId, slots, applied, match }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        referenceId = try c.decode(String.self, forKey: .referenceId)
        slots = c.o(.slots) ?? []
        applied = c.o(.applied)
        match = c.o(.match)
    }

    /// The total the "to generate" slots would cost, from the server's own estimates.
    public var toGenerateTotal: Double { generateTotal() }

    /// The same total with the slot estimates' prices where there are some, leaving out slots that can't be made.
    public func generateTotal(prices: [String: Double] = [:], unavailable: Set<String> = []) -> Double {
        slots.filter { $0.state == "to_generate" && !unavailable.contains($0.slotId) }
            .compactMap { prices[$0.slotId] ?? $0.estimate?.amount }.reduce(0, +)
    }
}

/// How close our version is to the reference, 0–1 per element (after apply).
public struct RecreateMatch: Codable, Hashable, Sendable {
    public struct PerSlot: Codable, Hashable, Sendable {
        public var slotId: String
        public var score: Double
    }
    public var overall: Double?
    public var cuts: Double?
    public var text: Double?
    public var ramps: Double?
    public var grade: Double?
    public var shots: Double?
    public var perSlot: [PerSlot]?
}

/// Plain words for the Recipe view (members see these; no model, provider or GPU names).
public enum RecreateText {
    public static func percent(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }

    public static func transition(_ kind: String) -> String {
        switch kind {
        case "cut": return "Cut"
        case "flash": return "Flash"
        case "whip": return "Whip"
        case "zoom": return "Zoom"
        case "fade": return "Fade"
        case "crossfade": return "Crossfade"
        case "glitch": return "Glitch"
        default: return "Not recognised"
        }
    }

    public static func camera(_ motion: String?) -> String? {
        switch motion {
        case "static": return "Still"
        case "pan": return "Pan"
        case "tilt": return "Tilt"
        case "zoom_in": return "Push in"
        case "zoom_out": return "Pull out"
        case "shake": return "Handheld shake"
        case "mixed": return "Mixed moves"
        default: return nil
        }
    }

    public static func speed(_ ramp: String?) -> String? {
        switch ramp {
        case "speed_up": return "Speeds up"
        case "slow_down": return "Slows down"
        case "freeze": return "Freeze"
        case "mixed": return "Speed ramps"
        default: return nil
        }
    }

    public static func fill(_ state: String) -> String {
        switch state {
        case "matched": return "From your takes"
        case "to_generate": return "To generate"
        case "generating": return "Generating"
        case "ready": return "Ready"
        default: return "Not filled"
        }
    }

    /// "0:01.5", for times in the reference.
    public static func time(_ sec: Double) -> String {
        let s = max(0, sec)
        let m = Int(s) / 60
        let rest = s - Double(m * 60)
        return String(format: "%d:%04.1f", m, rest)
    }
}
