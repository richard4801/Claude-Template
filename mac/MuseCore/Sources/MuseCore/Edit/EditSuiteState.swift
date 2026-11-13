import Foundation

// Edit suite (workstream 3): the editor screen's state and every editing action, kept here (pure, no UI or AVFoundation)
// so it is unit-tested on any platform. The Mac view model (Muse/App/Edit/EditSuiteSession) owns one EditSuiteState and
// adds playback, jobs and export around it. Every change to the project goes through `history`, so ⌘Z / ⇧⌘Z undo and
// redo all of them (up to 100 steps); selection, playhead, zoom and panel choices are view state and are not undone.

public enum EditSuite {
    /// The canvas shapes of the top bar and the export sheet.
    public enum Ratio: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
        case portrait = "9:16", square = "1:1", vertical = "4:5", landscape = "16:9"
        /// Parity (as Android): 4:3 and 2.35:1 (47:20 inside).
        case fourThree = "4:3", cinema = "2.35:1"
        public var id: String { rawValue }
        public var label: String { rawValue }
        /// Width : height.
        public var aspect: (w: Int, h: Int) {
            switch self {
            case .portrait: return (9, 16)
            case .square: return (1, 1)
            case .vertical: return (4, 5)
            case .landscape: return (16, 9)
            case .fourThree: return (4, 3)
            case .cinema: return (47, 20)
            }
        }
        /// The canvas at `shortSide` px on the short side (even sizes, as encoders want).
        public func canvas(shortSide: Int) -> (width: Int, height: Int) {
            let (a, b) = aspect
            func even(_ v: Double) -> Int { max(16, Int((v / 2).rounded()) * 2) }
            // The long side is capped at 4096 (2.35:1 at 4K = 4096 × 1744), the short side shrinking with it.
            let long = Double(shortSide) * Double(max(a, b)) / Double(min(a, b))
            let k = min(1, 4096 / long)
            let lg = long * k
            // Capped: the short side rounds up to even (4096 × 1744, as Android).
            let sh = k < 1 ? Double(max(16, Int((Double(shortSide) * k / 2).rounded(.up)) * 2)) : Double(even(Double(shortSide)))
            if a <= b { return (Int(sh), even(lg)) }
            return (even(lg), Int(sh))
        }
        /// The shape closest to a canvas.
        public static func nearest(width: Int, height: Int) -> Ratio {
            let r = Double(width) / Double(max(1, height))
            return allCases.min { abs(log(Double($0.aspect.w) / Double($0.aspect.h) / r)) < abs(log(Double($1.aspect.w) / Double($1.aspect.h) / r)) } ?? .portrait
        }
    }

    public enum Resolution: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
        case p720 = 720, p1080 = 1080, k2 = 1440, k4 = 2160
        public var id: Int { rawValue }
        public var label: String {
            switch self {
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .k2: return "2K"
            case .k4: return "4K"
            }
        }
    }

    public enum Codec: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
        case h264, hevc
        public var id: String { rawValue }
        public var label: String { self == .h264 ? "MP4 · H.264" : "HEVC" }
    }

    /// The export sheet's first choice (parity, as Android): a video, the mix alone as .m4a, or a looping GIF.
    public enum ExportFormat: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
        case video, sound, gif
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .video: return "Video"
            case .sound: return "Sound only"
            case .gif: return "GIF"
            }
        }
        public static let gifMaxSec = 30.0, gifFps = 15.0, gifShortSide = 480
        public static let soundBitrate = 192_000
    }

    /// Video bitrate against the size estimate's rate (parity, as Android).
    public enum Bitrate: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
        case smaller, recommended, higher
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .smaller: return "Smaller file"
            case .recommended: return "Recommended"
            case .higher: return "Higher quality"
            }
        }
        public var factor: Double {
            switch self {
            case .smaller: return 0.6
            case .recommended: return 1
            case .higher: return 1.6
            }
        }
    }

    public enum CaptionsOut: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
        case burnIn, srt
        public var id: String { rawValue }
        public var label: String { self == .burnIn ? "Burn in" : ".SRT file" }
    }

    public enum InspectorTab: String, CaseIterable, Hashable, Sendable, Identifiable {
        case captions, text, video, audio, speed, anim
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .captions: return "Captions"
            case .text: return "Text"
            case .video: return "Video"
            case .audio: return "Audio"
            case .speed: return "Speed"
            case .anim: return "Animate"
            }
        }
    }

    public enum BinTab: String, CaseIterable, Hashable, Sendable, Identifiable {
        case takes, uploads, music, text, stickers, templates
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .takes: return "Takes"
            case .uploads: return "Uploads"
            case .music: return "Music"
            case .text: return "Text"
            case .stickers: return "Stickers"
            case .templates: return "Templates"
            }
        }
    }

    public enum BeatMarks: String, CaseIterable, Hashable, Sendable { case every, strong }

    /// Caption position presets (style.y).
    public enum CaptionPosition: String, CaseIterable, Hashable, Sendable, Identifiable {
        case top, middle, lower
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .top: return "Top"
            case .middle: return "Middle"
            case .lower: return "Lower ⅓"
            }
        }
        public var y: Double {
            switch self {
            case .top: return 0.2
            case .middle: return 0.5
            case .lower: return 0.72
            }
        }
        public static func nearest(_ y: Double) -> CaptionPosition { allCases.min { abs($0.y - y) < abs($1.y - y) } ?? .lower }
    }

    /// The export sheet's choices (E4). Disclosure switches are per export and OFF by default (owner rule).
    public struct ExportSettings: Hashable, Sendable {
        public var ratio: Ratio = .portrait
        public var resolution: Resolution = .p1080
        public var fps: Int = 30
        public var codec: Codec = .h264
        public var captions: CaptionsOut = .burnIn
        public var labelAI = false
        public var c2pa = false
        /// Parity (as Android): what the export makes, and the video bitrate.
        public var format: ExportFormat = .video
        public var bitrate: Bitrate = .recommended
        /// XL (owner-approved 2026-11-09, Mac first): HDR video, HEVC 10-bit HLG (BT.2020). A video only; always HEVC.
        public var hdr = false
        /// With HDR: Dolby Vision 8.4 metadata on top of HLG (owner 2026-11-12: keep it, on by default). Off: plain HLG.
        public var dolbyVision = true
        public init() {}

        /// Whether the file gets Dolby Vision metadata: an HDR video with the switch on.
        public var writesDolbyVision: Bool { hdr && format == .video && dolbyVision }
        public static let frameRates = [24, 30, 60]

        /// The codec the file is written with: HDR is HEVC whatever `codec` says.
        public var effectiveCodec: Codec { hdr && format == .video ? .hevc : codec }

        public var size: (width: Int, height: Int) { ratio.canvas(shortSide: resolution.rawValue) }

        /// Video bit rate (bits/s) the size estimate assumes.
        public var videoBitrate: Double {
            let base: Double
            switch resolution {
            case .p720: base = 8e6
            case .p1080: base = 16e6
            case .k2: base = 28e6
            case .k4: base = 45e6
            }
            // Relative to a 9:16 / 16:9 frame of the same short side (a square has fewer pixels).
            let s = Double(resolution.rawValue)
            let px = Double(size.width * size.height) / (s * s * 16 / 9)
            let f = fps >= 60 ? 1.4 : fps <= 24 ? 0.9 : 1
            // HDR's 10 bits cost about a fifth more than 8-bit HEVC.
            return base * px * f * (effectiveCodec == .hevc ? 0.6 : 1) * (hdr && format == .video ? 1.2 : 1) * bitrate.factor
        }

        /// Roughly how big the file will be (bytes): video at `videoBitrate` + 128 kbps AAC.
        public func estimatedBytes(durationSec d: Double) -> Double {
            switch format {
            case .video: return max(0, d) * (videoBitrate + 128_000) / 8
            case .sound: return max(0, d) * 192_000 / 8
            case .gif: return max(0, min(d, ExportFormat.gifMaxSec)) * ExportFormat.gifFps * 480 * 853 * 0.35
            }
        }
        /// "≈ 38 MB"
        public func sizeLabel(durationSec d: Double) -> String {
            let mb = estimatedBytes(durationSec: d) / 1_000_000
            return mb >= 1000 ? String(format: "≈ %.1f GB", mb / 1000) : "≈ \(max(1, Int(mb.rounded()))) MB"
        }
        /// "0:18 · 1080 × 1920 · 30 fps"
        public func summary(durationSec d: Double) -> String {
            let (w, h) = size
            return "\(EditSuite.clock(d)) · \(w) × \(h) · \(fps) fps" + (hdr && format == .video ? " · HDR" : "")
        }
    }

    /// "0:18"
    public static func clock(_ s: Double) -> String {
        let n = Int(finiteSeconds(s).rounded())
        return "\(n / 60):" + (n % 60 < 10 ? "0" : "") + "\(n % 60)"
    }

    /// "0:04.2"
    public static func clockTenths(_ s: Double) -> String {
        let t = Int((finiteSeconds(s) * 10).rounded())
        let sec = (t / 10) % 60, m = t / 600
        return "\(m):" + (sec < 10 ? "0" : "") + "\(sec).\(t % 10)"
    }

    // MARK: Waveform peaks (owner crash 2026-11-07)

    /// Peak levels of decoded 16-bit PCM at any rate and channel count: each frame's loudest channel, kept as the max of
    /// each block of `block` frames (so a long take never holds every sample), then sliced into equal parts and normalised.
    public struct Peaks: Sendable {
        public let block: Int
        public private(set) var blocks: [Int32] = []
        private var cur: Int32 = 0
        private var inBlock = 0
        public init(block: Int = 64) { self.block = max(1, block) }

        /// Adds interleaved samples (`channels` per frame; a trailing partial frame is ignored).
        public mutating func add(interleaved s: [Int16], channels: Int) {
            let ch = max(1, channels)
            var i = 0
            while i + ch <= s.count {
                var m: Int32 = 0
                for c in 0..<ch { m = max(m, abs(Int32(s[i + c]))) }
                cur = max(cur, m)
                inBlock += 1
                if inBlock == block { blocks.append(cur); cur = 0; inBlock = 0 }
                i += ch
            }
        }

        /// `count` peaks (0…1) over everything added, the loudest scaled to 1 (quiet sound stays small: floor 0.05).
        /// Empty when nothing was added or `count` < 1.
        public func slices(_ count: Int) -> [Float] {
            var all = blocks
            if inBlock > 0 { all.append(cur) }
            guard count > 0, !all.isEmpty else { return [] }
            let n = min(count, all.count)
            var out: [Float] = []
            out.reserveCapacity(n)
            for k in 0..<n {
                let a = k * all.count / n, b = max(a + 1, (k + 1) * all.count / n)
                out.append(Float(all[a..<min(b, all.count)].max() ?? 0) / 32768)
            }
            let top = max(0.05, out.max() ?? 1)
            return out.map { min(1, $0 / top) }
        }
    }

    // MARK: Safe numbers (owner blocker 2026-11-07: Int(inf / NaN) crashed the editor on real takes)

    /// Seconds a clock can show: NaN, negative and infinite become 0, and anything past 100 hours is capped.
    public static func finiteSeconds(_ s: Double) -> Double { s.isFinite ? min(max(0, s), 360_000) : 0 }
    /// An Int from a Double that may be NaN or infinite (`Int(x)` traps on those): nil when it isn't a finite number.
    public static func int(_ x: Double) -> Int? { x.isFinite && abs(x) < 1e15 ? Int(x) : nil }
    /// The most thumbnail tiles a timeline block draws.
    public static let maxTiles = 400
    /// Thumbnail tiles across a block `width` wide: at least 1, at most `maxTiles`, whatever the width (NaN, infinite).
    public static func tileCount(width: Double, tileWidth: Double) -> Int {
        guard tileWidth > 0, let n = int((width / tileWidth).rounded(.up)) else { return 1 }
        return min(maxTiles, max(1, n))
    }
    /// Which of `count` frames (or waveform peaks) spread over the source shows source time `source`. The source length
    /// is the asset's `durationSec`, else `fallbackSec`; when neither is a positive finite number, frame 0. Nil when
    /// there are no frames. Never out of range, never traps.
    public static func frameIndex(source: Double, durationSec: Double?, fallbackSec: Double, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let d = [durationSec ?? .nan, fallbackSec].first { $0.isFinite && $0 > 0 }
        guard let d, source.isFinite, let i = int(source / d * Double(count)) else { return 0 }
        return min(count - 1, max(0, i))
    }

    /// One row of the timeline (top to bottom as the design draws them: hook/text, captions, overlays, stickers, video,
    /// voice, music, sfx).
    public struct Row: Hashable, Sendable, Identifiable {
        public var id: String { trackId }
        public var trackId: String
        public var kind: EditV2.TrackKind
        public var label: String
        public var icon: String
    }

    /// A block on a row: an item, or a caption page on the captions row.
    public struct Block: Hashable, Sendable, Identifiable {
        public var id: String
        public var itemId: String?
        public var startSec: Double
        public var endSec: Double
        public var label: String
        /// Main clips: the transition into this clip (a diamond at its start).
        public var transition: EditV2.TransitionKind?
    }

    /// A beat mark on the timeline.
    public struct Beat: Hashable, Sendable {
        public var t: Double
        public var strong: Bool
    }

    /// Transcript word for the Captions & hooks screen (E3).
    public struct TranscriptWord: Hashable, Sendable, Identifiable {
        public var id: Int { index }
        public var index: Int
        public var text: String
        public var startSec: Double
        public var endSec: Double
        public var isFiller: Bool
        /// Still in the edit (its middle is inside a kept part of a main clip).
        public var kept: Bool
        /// The pause after this word (source seconds) when it is a cuttable silence, else nil.
        public var pauseAfter: Double?
    }
}

/// The editor's state. `project` changes only through `history`.
public struct EditSuiteState: Sendable {
    public typealias E = EditV2
    public private(set) var history: E.History
    public var project: E.Project { history.current }

    public var selection: String?
    public var playhead: Double = 0
    /// Timeline zoom, points per second.
    public var zoom: Double = 64
    public static let zoomRange: ClosedRange<Double> = 12...400
    public var ripple = true
    public var snapToBeats = false
    public var beatMarks: EditSuite.BeatMarks = .strong
    /// Locked rows can't be selected or changed from the timeline (view state).
    public var locked: Set<String> = []
    public var tab: EditSuite.InspectorTab = .captions
    /// The preview's view (Clean or a platform's chrome) and the red safe-area box (plans/edit-platform-preview.md). The app
    /// sets it from the remembered choice for this project.
    public var preview = EditPreview()
    public var export = EditSuite.ExportSettings()
    /// The last saved project (for "saved just now" / unsaved changes).
    public private(set) var savedProject: E.Project?
    /// The suite looks ("palette:<id>") this app ships, so the validity guard accepts them (set by the app).
    public var paletteIds: Set<String> = []
    /// Why the last change was refused (it would have broken a rule the server checks, e.g. text running into the next
    /// item); nil after a change that went through. The app shows it.
    public private(set) var lastRefusal: E.EditProblem?
    /// Records why an action couldn't be done, in words for the person (field "user"; the app shows the message as it is).
    public mutating func refuse(_ message: String) { lastRefusal = E.EditProblem("user", message) }
    /// The project when the current drag began: trims and moves are measured from it, so a drag's target is absolute
    /// (owner audit 2026-11-08: the start handle of a main clip measured from the already-trimmed clip and ran away).
    public private(set) var gestureBase: E.Project?
    /// The last shape switch (setRatio), for an exact switch back.
    public private(set) var shapeReturn: ShapeReturn?

    public init(_ project: E.Project) {
        history = E.History(project)
        export.ratio = EditSuite.Ratio.nearest(width: project.canvas.width, height: project.canvas.height)
        export.fps = [24, 30, 60].min { abs(Double($0) - project.canvas.fps) < abs(Double($1) - project.canvas.fps) } ?? 30
        export.resolution = min(project.canvas.width, project.canvas.height) >= 2000 ? .k4 : min(project.canvas.width, project.canvas.height) <= 800 ? .p720 : .p1080
        selection = project.mainClips.first?.id
    }

    public var duration: Double { E.durationSec(project) }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    public var hasUnsavedChanges: Bool { savedProject != project }
    public mutating func markSaved() { savedProject = project }

    // MARK: History

    /// Applies an operation (nil = nothing to do); keeps the selection and playhead valid. Returns whether it changed.
    @discardableResult
    public mutating func apply(_ op: (E.Project) -> E.Project?) -> Bool {
        // Owner audit 2026-11-08: a change must never leave a project the server refuses (and Export blocks), e.g. a text
        // lengthened over the next one. A project that is already off (older data) may still change.
        let before = project
        var refusal: E.EditProblem?
        let pal = paletteIds
        let ok = history.apply { p in
            guard let next = op(p) else { return nil }
            if let bad = E.problem(next, paletteIds: pal), E.problem(before, paletteIds: pal) == nil { refusal = bad; return nil }
            return next
        }
        lastRefusal = refusal
        guard ok else { return false }
        settle()
        return true
    }

    /// Edit sessions (workstream 3): shows a change from another device or Claude. It isn't a local undo step; the local steps
    /// are rebased onto it (EditV2.History.adoptRemote). Returns whether the project changed.
    @discardableResult
    public mutating func applyRemote(_ p: E.Project) -> Bool {
        guard p != project else { return false }
        history.adoptRemote(p)
        settle()
        return true
    }

    @discardableResult public mutating func undo() -> Bool { guard history.undo() else { return false }; settle(); return true }
    @discardableResult public mutating func redo() -> Bool { guard history.redo() else { return false }; settle(); return true }

    /// A drag: one undo step for the whole gesture.
    public mutating func beginGesture() { history.begin(); gestureBase = project }
    public mutating func updateGesture(_ next: E.Project?) {
        guard let p = next, p != project else { return }
        // A drag never goes past what the server accepts (it stops at the last valid position).
        if E.problem(p, paletteIds: paletteIds) != nil, E.problem(project, paletteIds: paletteIds) == nil { return }
        history.update(p)
        settle()
    }
    public mutating func endGesture() { history.end(); gestureBase = nil }

    private mutating func settle() {
        playhead = min(max(0, playhead), duration)
        if let s = selection, project.locate(s) == nil { selection = nil }
        if selection == nil { selection = project.mainClip(at: playhead).map { project.mainClips[$0.index].id } }
    }

    // MARK: Selection

    public var selectedItem: E.Item? { selection.flatMap { id in project.locate(id).map { project.tracks[$0.track].items[$0.item] } } }
    public var selectedTrack: E.Track? { selection.flatMap { id in project.locate(id).map { project.tracks[$0.track] } } }
    public var selectedVideo: E.VideoClip? { selectedItem?.videoClip }
    public var selectedIsMain: Bool { selectedTrack?.kind == .main }

    /// Selects what is under timeline t on a row (or the main clip there).
    public mutating func select(at t: Double, trackId: String? = nil) {
        guard let tid = trackId, let track = project.track(tid), track.kind != .main else {
            selection = project.mainClip(at: t).map { project.mainClips[$0.index].id }
            return
        }
        if locked.contains(tid) { return }
        selection = track.items.first { t >= $0.startSec - 1e-9 && t < $0.startSec + $0.lengthSec }?.id
    }

    public func isLocked(_ itemId: String) -> Bool {
        guard let loc = project.locate(itemId) else { return false }
        return locked.contains(project.tracks[loc.track].id)
    }

    // MARK: Rows and blocks

    public static func defaultLabel(_ k: E.TrackKind) -> String {
        switch k {
        case .main: return "Video"
        case .video: return "Overlay"
        case .image: return "Stickers"
        case .text: return "Text"
        case .caption: return "Captions"
        case .music: return "Music"
        case .voice: return "Voice"
        case .sfx: return "SFX"
        case .adjust: return "Adjustment"
        }
    }

    public static func icon(_ k: E.TrackKind) -> String {
        switch k {
        case .main: return "video"
        case .video: return "square.stack"
        case .image: return "face.smiling"
        case .text: return "textformat"
        case .caption: return "captions.bubble"
        case .music: return "music.note"
        case .voice: return "mic"
        case .sfx: return "speaker.wave.2"
        case .adjust: return "sliders-horizontal"
        }
    }

    public var rows: [EditSuite.Row] {
        let order: [E.TrackKind] = [.text, .caption, .adjust, .video, .image, .main, .voice, .music, .sfx]
        var out: [EditSuite.Row] = []
        for k in order {
            // Later tracks draw on top: show them higher (the Hook row always first).
            let tracks = project.tracks.reversed().filter { $0.kind == k }
            for t in tracks.filter({ $0.name == "Hook" }) + tracks.filter({ $0.name != "Hook" }) {
                out.append(EditSuite.Row(trackId: t.id, kind: t.kind, label: t.name ?? Self.defaultLabel(t.kind), icon: Self.icon(t.kind)))
            }
        }
        return out
    }

    public func blocks(_ trackId: String) -> [EditSuite.Block] {
        guard let t = project.track(trackId) else { return [] }
        switch t.kind {
        case .caption:
            return E.captionPages(project).enumerated().map { i, pg in
                EditSuite.Block(id: "\(trackId)#\(i)", itemId: nil, startSec: pg.startSec, endSec: pg.endSec,
                                label: E.captionText(pg.words.map(\.text), project.captionTrack?.language), transition: nil)
            }
        case .main:
            let spans = E.timeline(project)
            return project.mainClips.enumerated().map { i, c in
                EditSuite.Block(id: c.id, itemId: c.id, startSec: spans[i].startSec, endSec: spans[i].endSec, label: label(c.asset), transition: c.transitionIn?.kind)
            }
        default:
            return t.items.map { it in
                let span = E.itemSpan(project, t, it)
                let l: String
                switch it {
                case .text(let x): l = x.text.replacingOccurrences(of: "\n", with: " ")
                case .video(let c): l = label(c.asset)
                case .image(let c): l = label(c.asset)
                case .audio(let c): l = label(c.asset)
                case .adjust: l = "Adjustment"
                }
                return EditSuite.Block(id: it.id, itemId: it.id, startSec: span.startSec, endSec: span.endSec, label: l, transition: nil)
            }
        }
    }

    /// Asset names shown on blocks (set by the app from take titles / file names).
    public var assetNames: [String: String] = [:]
    func label(_ assetId: String) -> String { assetNames[assetId] ?? assetId }

    // MARK: Beats

    /// Beat marks of the music tracks on the timeline (every beat, or only the strong ones).
    public var beats: [EditSuite.Beat] {
        var out: [EditSuite.Beat] = []
        for t in project.tracks where t.kind == .music {
            for case .audio(let c) in t.items {
                let strong = Set((c.strongBeats ?? []).map { E.r3($0) })
                for b in c.beats ?? [] where b >= c.inSec && b <= c.outSec {
                    let s = strong.contains(E.r3(b))
                    if beatMarks == .strong && !s && !strong.isEmpty { continue }
                    let tl = c.startSec + (b - c.inSec) / (c.speed ?? 1)
                    if tl <= duration { out.append(EditSuite.Beat(t: E.r6(tl), strong: s)) }
                }
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    /// BPM of the first music clip with beats (from the gaps), or nil.
    public var bpm: Double? {
        for t in project.tracks where t.kind == .music {
            for case .audio(let c) in t.items {
                if let b = c.beats, b.count > 2 { return E.r3(60 / ((b[b.count - 1] - b[0]) / Double(b.count - 1))) }
            }
        }
        return nil
    }

    /// t moved to the nearest beat mark within `tolerance` seconds when "Snap cuts to beats" is on.
    public func snapped(_ t: Double, tolerance: Double = 0.12) -> Double {
        guard snapToBeats else { return t }
        guard let b = beats.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(b.t - t) <= tolerance else { return t }
        return b.t
    }

    // MARK: Cutting

    /// S: splits the selected non-main item under the playhead, else the main clip there (at the beat when snapping).
    @discardableResult
    public mutating func split() -> Bool {
        let t = snapped(playhead)
        if let s = selection, let loc = project.locate(s), project.tracks[loc.track].kind != .main, !locked.contains(project.tracks[loc.track].id) {
            var newId: String?
            let ok = apply { p in
                guard let r = p.splittingItem(s, at: t) else { return nil }
                newId = r.newId
                return r.project
            }
            if ok { selection = newId }
            return ok
        }
        if let main = project.mainTrack, locked.contains(main.id) { return false }
        var newId: String?
        let ok = apply { p in
            guard let r = p.splittingMainClip(at: t) else { return nil }
            newId = r.newId
            return r.project
        }
        if ok { selection = newId }
        return ok
    }

    /// ⌫: deletes the selection. With Ripple on, a deleted main clip pulls everything after it left on the other tracks too
    /// (they stay in sync) and a deleted overlay item closes its gap.
    @discardableResult
    public mutating func deleteSelected() -> Bool {
        guard let s = selection, !isLocked(s), let loc = project.locate(s) else { return false }
        let rip = ripple
        let track = project.tracks[loc.track]
        let span = E.itemSpan(project, track, track.items[loc.item])
        let ok = apply { p in
            guard var q = p.removing(s) else { return nil }
            guard rip else { return q }
            if track.kind == .main {
                let removed = E.durationSec(p) - E.durationSec(q)
                q = q.shiftingItems(after: span.startSec, by: -removed, except: [track.id])
            } else {
                q = q.shiftingItems(after: span.endSec - 1e-6, by: -(span.endSec - span.startSec), only: [track.id])
            }
            return q
        }
        if ok { selection = nil; settleSelection() }
        return ok
    }

    private mutating func settleSelection() {
        selection = project.mainClip(at: playhead).map { project.mainClips[$0.index].id }
    }

    /// Removes source ranges of the main asset(s) (silences, fillers, words deleted in the transcript).
    @discardableResult
    public mutating func applyCuts(_ cuts: [E.SecRange], assetId: String) -> Bool {
        guard !cuts.isEmpty else { return false }
        return apply { p in
            let q = E.applyCuts(p, assetId: assetId, cuts: cuts).uniquingMainIds()
            return q == p ? nil : q
        }
    }

    // MARK: Trim and move (timeline gestures)

    public enum Edge: Sendable { case start, end }

    /// Trims an item's edge to timeline time `t` (snapped to beats when on). Main clips change their source in/out (the
    /// clips after follow); other items change start/length. Use inside begin/updateGesture/endGesture for drags.
    public func trimming(_ itemId: String, _ edge: Edge, to rawT: Double) -> E.Project? {
        let t = snapped(rawT)
        let p = gestureBase ?? project
        guard !isLocked(itemId), let loc = p.locate(itemId) else { return nil }
        let track = p.tracks[loc.track]
        let item = track.items[loc.item]
        let span = E.itemSpan(p, track, item)
        let minLen = 0.1
        return p.updating(itemId) { it in
            switch it {
            case .video(var c) where c.holdSec != nil:
                // Wave 1: trimming a freeze frame changes how long it holds.
                let len = edge == .start ? span.endSec - t : t - span.startSec
                let h = E.r3(min(E.holdMaxSec, max(E.holdMinSec, len)))
                if edge == .start && track.kind != .main { c.startSec = E.r6(span.endSec - h) }
                c.holdSec = h
                it = .video(c)
            case .video(var c):
                let dur = p.asset(c.asset)?.durationSec ?? .infinity
                let sp = edge == .start ? (E.speedPieces(c).first?.speed ?? c.speed) : (E.speedPieces(c).last?.speed ?? c.speed)
                if edge == .start {
                    let d = (t - span.startSec) * sp
                    c.inSec = E.r6(min(max(0, c.inSec + d), c.outSec - minLen))
                    if track.kind != .main { c.startSec = E.r6(max(0, span.startSec + (c.inSec - (it.videoClip!.inSec)) / sp)) }
                } else {
                    let d = (t - span.endSec) * sp
                    c.outSec = E.r6(max(min(dur, c.outSec + d), c.inSec + minLen))
                }
                it = .video(c)
            case .audio(var c):
                let dur = p.asset(c.asset)?.durationSec ?? .infinity
                let sp = c.speed ?? 1
                if edge == .start {
                    let old = c.inSec
                    c.inSec = E.r6(min(max(0, c.inSec + (t - span.startSec) * sp), c.outSec - minLen))
                    c.startSec = E.r6(max(0, c.startSec + (c.inSec - old) / sp))
                } else {
                    c.outSec = E.r6(max(min(dur, c.outSec + (t - span.endSec) * sp), c.inSec + minLen))
                }
                it = .audio(c)
            case .image(var c):
                if edge == .start {
                    let s = min(max(0, t), span.endSec - E.minItemSec)
                    c.durationSec = E.r6(span.endSec - s); c.startSec = E.r6(s)
                } else { c.durationSec = E.r6(max(E.minItemSec, t - span.startSec)) }
                it = .image(c)
            case .text(var c):
                if edge == .start {
                    let s = min(max(0, t), span.endSec - E.minItemSec)
                    c.durationSec = E.r6(span.endSec - s); c.startSec = E.r6(s)
                } else { c.durationSec = E.r6(max(E.minItemSec, t - span.startSec)) }
                it = .text(c)
            case .adjust(var c):
                if edge == .start {
                    let s = min(max(0, t), span.endSec - E.minItemSec)
                    c.durationSec = E.r6(span.endSec - s); c.startSec = E.r6(s)
                } else { c.durationSec = E.r6(max(E.minItemSec, t - span.startSec)) }
                it = .adjust(c)
            }
        }.flatMap { q in q.overlapFree(trackIndex: loc.track) ? q : nil }
    }

    /// Moves a non-main item so it starts at `t` (snapped), optionally to another row of a suitable kind.
    public func moving(_ itemId: String, to rawT: Double, track: String? = nil) -> E.Project? {
        guard !isLocked(itemId) else { return nil }
        if let track, locked.contains(track) { return nil }
        return (gestureBase ?? project).moving(itemId, toStartSec: E.r6(max(0, snapped(rawT))), track: track)
    }

    /// Moves a main clip to another place in the sequence.
    @discardableResult
    public mutating func moveMainClip(_ id: String, to index: Int) -> Bool {
        guard !isLocked(id) else { return false }
        return apply { $0.movingMainClip(id, to: index) }
    }

    // MARK: Tracks

    @discardableResult
    public mutating func toggleHidden(_ trackId: String) -> Bool {
        apply { p in
            guard let i = p.tracks.firstIndex(where: { $0.id == trackId }) else { return nil }
            var q = p
            q.tracks[i].hidden = q.tracks[i].hidden == true ? nil : true
            return q
        }
    }

    @discardableResult
    public mutating func toggleMuted(_ trackId: String) -> Bool {
        apply { p in
            guard let i = p.tracks.firstIndex(where: { $0.id == trackId }) else { return nil }
            var q = p
            q.tracks[i].muted = q.tracks[i].muted == true ? nil : true
            return q
        }
    }

    public mutating func toggleLocked(_ trackId: String) {
        if locked.contains(trackId) { locked.remove(trackId) } else { locked.insert(trackId) }
        if let s = selection, isLocked(s) { selection = nil }
    }

    // MARK: Item properties

    /// Changes the selected item (one undo step). Returns whether anything changed.
    @discardableResult
    public mutating func changeSelected(_ change: (inout E.Item) -> Void) -> Bool {
        guard let s = selection, !isLocked(s) else { return false }
        return apply { $0.updating(s, change) }
    }

    /// Changes the selected video/overlay clip.
    @discardableResult
    public mutating func changeVideo(_ change: @escaping (inout E.VideoClip) -> Void) -> Bool {
        changeSelected { it in if case .video(var c) = it { change(&c); it = .video(c) } }
    }

    /// Changes the selected video or image item's shared visual fields (adjust, look, mask) through a VisualFields box.
    @discardableResult
    public mutating func changeVisual(_ change: @escaping (inout EditSuite.Visual) -> Void) -> Bool {
        changeSelected { it in
            switch it {
            case .video(var c):
                var v = EditSuite.Visual(adjust: c.adjust, look: c.look, mask: c.mask, chroma: c.chroma, transform: c.transform, opacity: c.opacity, keyframes: c.keyframes, crop: c.crop)
                change(&v)
                c.adjust = v.adjust; c.look = v.look; c.mask = v.mask; c.chroma = v.chroma; c.transform = v.transform; c.opacity = v.opacity; c.keyframes = v.keyframes
                c.crop = v.crop
                it = .video(c)
            case .image(var c):
                var v = EditSuite.Visual(adjust: c.adjust, look: c.look, mask: c.mask, chroma: nil, transform: c.transform, opacity: c.opacity, keyframes: c.keyframes, crop: c.crop)
                change(&v)
                c.adjust = v.adjust; c.look = v.look; c.mask = v.mask; c.transform = v.transform; c.opacity = v.opacity; c.keyframes = v.keyframes
                c.crop = v.crop
                it = .image(c)
            case .text(var c):
                var v = EditSuite.Visual(adjust: nil, look: nil, mask: nil, chroma: nil, transform: c.transform, opacity: c.opacity, keyframes: c.keyframes)
                change(&v)
                c.transform = v.transform; c.opacity = v.opacity; c.keyframes = v.keyframes
                it = .text(c)
            case .adjust(var c):
                // An adjustment layer: its colour, strength (opacity) and keyframes.
                var v = EditSuite.Visual(adjust: c.adjust, look: nil, mask: nil, chroma: nil, transform: nil, opacity: c.opacity, keyframes: c.keyframes)
                change(&v)
                c.adjust = v.adjust; c.opacity = v.opacity; c.keyframes = v.keyframes
                it = .adjust(c)
            case .audio:
                break
            }
        }
    }

    /// The selected visual's fields (nil for audio).
    public var selectedVisual: EditSuite.Visual? {
        switch selectedItem {
        case .video(let c): return EditSuite.Visual(adjust: c.adjust, look: c.look, mask: c.mask, chroma: c.chroma, transform: c.transform, opacity: c.opacity, keyframes: c.keyframes, crop: c.crop)
        case .image(let c): return EditSuite.Visual(adjust: c.adjust, look: c.look, mask: c.mask, chroma: nil, transform: c.transform, opacity: c.opacity, keyframes: c.keyframes, crop: c.crop)
        case .text(let c): return EditSuite.Visual(adjust: nil, look: nil, mask: nil, chroma: nil, transform: c.transform, opacity: c.opacity, keyframes: c.keyframes)
        case .adjust(let c): return EditSuite.Visual(adjust: c.adjust, look: nil, mask: nil, chroma: nil, transform: nil, opacity: c.opacity, keyframes: c.keyframes)
        default: return nil
        }
    }

    /// Adds (or replaces) a keyframe of `prop` at the playhead on the selected item, with the item's current value.
    @discardableResult
    public mutating func addKeyframe(_ prop: E.KfProp, value: Double, ease: E.Ease = .easeInOut) -> Bool {
        guard let s = selection, let loc = project.locate(s) else { return false }
        let track = project.tracks[loc.track]
        let span = E.itemSpan(project, track, track.items[loc.item])
        let local = E.r6(min(max(0, playhead - span.startSec), span.endSec - span.startSec))
        return changeVisual { v in
            var k = v.keyframes ?? E.Keyframes()
            var list = (k[prop] ?? []).filter { abs($0.t - local) > 1e-6 }
            list.append(E.Keyframe(t: local, v: value, ease: ease))
            list.sort { $0.t < $1.t }
            k[prop] = list
            v.keyframes = k
        }
    }

    /// Sets every keyframe's ease on the selected item (the Ease row of Transform & keyframes).
    @discardableResult
    public mutating func setKeyframeEase(_ ease: E.Ease) -> Bool {
        changeVisual { v in
            guard var k = v.keyframes else { return }
            for (p, list) in k.present { k[p] = list.map { E.Keyframe(t: $0.t, v: $0.v, ease: ease) } }
            v.keyframes = k
        }
    }

    // MARK: Speed

    /// Constant speed (0.1–10) on the selected clip; removes its curve.
    @discardableResult
    public mutating func setSpeed(_ s: Double) -> Bool {
        let v = min(E.maxSpeed, max(E.minSpeed, (s * 100).rounded() / 100))
        return changeSpeed { c in c.speed = v; c.speedCurve = nil }
    }

    /// A curve preset (or nil = constant again).
    @discardableResult
    public mutating func setSpeedPreset(_ preset: E.SpeedPreset?) -> Bool {
        changeSpeed { c in
            guard let preset else { c.speedCurve = nil; return }
            if let curve = E.speedCurve(preset) { c.speedCurve = curve; c.speed = 1 }
            else if c.speedCurve == nil { c.speedCurve = E.SpeedCurve(preset: .custom, points: [[0, c.speed], [1, c.speed]]) }
            else { c.speedCurve?.preset = .custom }
        }
    }

    /// Moves curve point `i` (x kept between its neighbours; the end points stay at 0 and 1), speed clamped; the preset
    /// becomes custom.
    public static func movingCurvePoint(_ curve: E.SpeedCurve, _ i: Int, x: Double, speed: Double) -> E.SpeedCurve {
        var c = curve
        guard c.points.indices.contains(i) else { return c }
        let lo = i == 0 ? 0 : c.points[i - 1][0] + 0.01, hi = i == c.points.count - 1 ? 1 : c.points[i + 1][0] - 0.01
        let nx = i == 0 ? 0 : i == c.points.count - 1 ? 1 : min(hi, max(lo, x))
        c.points[i] = [E.r6(nx), E.r6(min(E.maxSpeed, max(E.minSpeed, speed)))]
        c.preset = .custom
        return c
    }

    /// Adds a point on the curve at x (at most 16).
    public static func addingCurvePoint(_ curve: E.SpeedCurve, x: Double) -> E.SpeedCurve {
        var c = curve
        guard c.points.count < 16, x > 0.01, x < 0.99, !c.points.contains(where: { abs($0[0] - x) < 0.02 }) else { return c }
        c.points.append([E.r6(x), E.r6(E.curveSpeed(curve, x))])
        c.points.sort { $0[0] < $1[0] }
        c.preset = .custom
        return c
    }

    @discardableResult
    public mutating func setSpeedCurve(_ curve: E.SpeedCurve) -> Bool { changeSpeed { $0.speedCurve = curve } }

    /// Changes speed fields of the selected video clip, refusing a change that breaks a transition (the timeline length
    /// changed) by dropping transitions that no longer fit.
    private mutating func changeSpeed(_ change: @escaping (inout E.VideoClip) -> Void) -> Bool {
        guard let s = selection, !isLocked(s) else { return false }
        return apply { p in
            guard var q = p.updating(s, { it in if case .video(var c) = it { change(&c); it = .video(c) } }) else { return nil }
            if let mi = q.tracks.firstIndex(where: { $0.kind == .main }) { q.tracks[mi].items = E.Project.fixTransitions(q.tracks[mi].items) }
            if q.tracks.contains(where: { $0.kind != .main }) {
                // An overlay clip that now overlaps the next item keeps its old speed.
                for (ti, t) in q.tracks.enumerated() where t.kind != .main && !q.overlapFree(trackIndex: ti) { return nil }
            }
            return q
        }
    }

    /// "6.2 s → 4.1 s": the selected clip's source length and timeline length.
    public var speedSummary: String? {
        guard let c = selectedVideo else { return nil }
        return String(format: "%.1f s → %.1f s", c.outSec - c.inSec, E.clipLength(c))
    }

    // MARK: Transitions

    /// Sets the transition into the selected main clip ("cut" = nil). Durations are clamped to what fits.
    @discardableResult
    public mutating func setTransition(_ kind: E.TransitionKind?, duration: Double) -> Bool {
        guard let s = selection, selectedIsMain else { return false }
        return apply { p in p.settingTransitionFitted(s, kind, duration: duration) }
    }

    /// "Apply to all cuts": the same transition between every pair of main clips.
    @discardableResult
    public mutating func applyTransitionToAll(_ kind: E.TransitionKind?, duration: Double) -> Bool {
        apply { p in
            var q = p
            for c in p.mainClips.dropFirst() { q = q.settingTransitionFitted(c.id, kind, duration: duration) ?? q }
            return q == p ? nil : q
        }
    }

    // MARK: Captions

    /// Adds (or replaces) the caption track from a transcript of `assetId` (source seconds), in the given style.
    @discardableResult
    public mutating func setCaptions(words: [E.Word], assetId: String, preset: E.CaptionPreset = .pop) -> Bool {
        let cw = words.prefix(E.maxWords).map { E.CaptionWord(text: String($0.text.prefix(60)), startSec: $0.startSec, endSec: max($0.startSec, $0.endSec)) }
            .filter { !$0.text.isEmpty }
        return apply { p in
            var q = p
            let style = p.captionTrack?.style ?? E.captionStyle(preset)
            let ct = E.CaptionTrack(asset: assetId, words: Array(cw), style: style)
            if let i = q.tracks.firstIndex(where: { $0.kind == .caption }) { q.tracks[i].caption = ct }
            else {
                guard q.tracks.count < E.maxTracks else { return nil }
                q.tracks.append(E.Track(id: q.newId("cap"), kind: .caption, name: "Captions", caption: ct))
            }
            return q
        }
    }

    public var captionStyle: E.CaptionStyle? { project.captionTrack?.style }

    /// Changes the caption style (choosing a preset takes that preset's look but keeps the position).
    @discardableResult
    public mutating func changeCaptionStyle(_ change: @escaping (inout E.CaptionStyle) -> Void) -> Bool {
        apply { p in
            guard let i = p.tracks.firstIndex(where: { $0.kind == .caption && $0.caption != nil }) else { return nil }
            var q = p
            change(&q.tracks[i].caption!.style)
            return q
        }
    }

    @discardableResult
    public mutating func setCaptionPreset(_ preset: E.CaptionPreset) -> Bool {
        changeCaptionStyle { s in
            let y = s.y
            s = E.captionStyle(preset)
            if let y { s.y = y }
        }
    }

    /// Word-by-word highlight on/off: off = the Minimal look of the current style (no active word).
    public var wordHighlight: Bool { (captionStyle?.preset ?? .plain) != .plain }

    /// The transcript for E3: every caption word with its filler flag, whether it's still in the edit, and cuttable pauses.
    public func transcript(minSilenceSec: Double = 0.7) -> [EditSuite.TranscriptWord] {
        guard let ct = project.captionTrack else { return [] }
        let kept = Set(E.captionWords(project).map(\.index))
        let fillers = Set(E.fillerWords)
        return ct.words.enumerated().map { i, w in
            let next = i + 1 < ct.words.count ? ct.words[i + 1] : nil
            let gap = next.map { $0.startSec - w.endSec } ?? 0
            return EditSuite.TranscriptWord(index: i, text: w.text, startSec: w.startSec, endSec: w.endSec, isFiller: fillers.contains(E.normWord(w.text)),
                                            kept: kept.contains(i), pauseAfter: gap >= minSilenceSec ? E.r3(gap) : nil)
        }
    }

    /// Fixes a word's spelling (its timing stays).
    @discardableResult
    public mutating func editWord(_ index: Int, text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 60 else { return false }
        return apply { p in
            guard let i = p.tracks.firstIndex(where: { $0.kind == .caption && $0.caption != nil }), p.tracks[i].caption!.words.indices.contains(index) else { return nil }
            var q = p
            q.tracks[i].caption!.words[index].text = t
            return q
        }
    }

    /// "Edit by text": deleting words cuts their stretch of the video (jump cuts). Neighbouring words are joined, so the
    /// pause between two deleted words goes too.
    @discardableResult
    public mutating func deleteWords(_ indices: Set<Int>) -> Bool {
        guard let ct = project.captionTrack, !indices.isEmpty else { return false }
        let sorted = indices.sorted().filter { ct.words.indices.contains($0) }
        var ranges: [E.SecRange] = []
        for i in sorted {
            let w = ct.words[i]
            var r = E.SecRange(startSec: w.startSec, endSec: w.endSec)
            if indices.contains(i + 1), i + 1 < ct.words.count { r.endSec = ct.words[i + 1].startSec }
            ranges.append(r)
        }
        return applyCuts(ranges, assetId: ct.asset)
    }

    /// The filler words still in the edit, as cuts.
    public var fillerCuts: [E.SecRange] {
        transcript().filter { $0.isFiller && $0.kept }.map { E.SecRange(startSec: $0.startSec, endSec: $0.endSec) }
    }

    /// The cuttable pauses still in the edit (keeping `pad` of each side).
    public func silenceCuts(minSilenceSec: Double = 0.7, pad: Double = 0.12) -> [E.SecRange] {
        let ws = transcript(minSilenceSec: minSilenceSec)
        return ws.compactMap { w in
            guard let gap = w.pauseAfter, w.kept else { return nil }
            let s = w.endSec + pad, e = w.endSec + gap - pad
            return e - s >= 0.1 ? E.SecRange(startSec: E.r3(s), endSec: E.r3(e)) : nil
        }
    }

    // MARK: Hooks and text

    /// Adds a hook (template) on the Hook text row at `startSec` (default 0, the first seconds), making the row if needed.
    @discardableResult
    public mutating func addHook(_ template: E.HookTemplate, text: String? = nil, at startSec: Double = 0) -> Bool {
        var newId: String?
        let ok = apply { p in
            var q = p
            var tid = q.tracks.first { $0.kind == .text && $0.name == "Hook" }?.id
            if tid == nil {
                guard let r = q.addingTrack(.text, name: "Hook") else { return nil }
                q = r.project
                tid = r.trackId
            }
            let id = q.newId("hook")
            let d = min(template.durationSec, max(E.minItemSec, E.durationSec(q) - startSec))
            var item = template.item(id: id, startSec: E.r6(startSec), text: text)
            item.durationSec = E.r6(d)
            // Replace a hook already at that time.
            if let t = q.track(tid!), let clash = t.items.first(where: { startSec < $0.startSec + $0.lengthSec && $0.startSec < startSec + d }) {
                guard let r = q.removing(clash.id) else { return nil }
                q = r
            }
            guard let r = q.adding(.text(item), toTrack: tid!) else { return nil }
            newId = id
            return r
        }
        if ok { selection = newId; tab = .text }
        return ok
    }

    /// Adds a plain text item at the playhead on a text row.
    @discardableResult
    public mutating func addText(_ text: String = "Your text", style: E.TextStyle? = nil) -> Bool {
        var newId: String?
        let at = playhead
        let ok = apply { p in
            var q = p
            let d = min(3, max(E.minItemSec, E.durationSec(q) - at))
            guard d >= E.minItemSec else { return nil }
            let id = q.newId("txt")
            let item = E.TextItem(id: id, startSec: E.r6(at), durationSec: E.r6(d), text: text,
                                  style: style ?? E.TextStyle(font: .sans, weight: 900, sizePct: 0.05, color: "#FFFFFF", align: .center, maxWidthPct: 0.85,
                                                              lineHeight: 1.15, stroke: E.Stroke(color: "#000000", widthPct: 0.12)),
                                  transform: E.Transform(x: 0.5, y: 0.5), animIn: E.Anim(kind: .pop, durationSec: 0.3))
            for t in q.tracks where t.kind == .text && t.name != "Hook" {
                if let r = q.adding(.text(item), toTrack: t.id) { newId = id; return r }
            }
            guard let r = q.addingTrack(.text, name: "Text") else { return nil }
            newId = id
            return r.project.adding(.text(item), toTrack: r.trackId)
        }
        if ok { selection = newId; tab = .text }
        return ok
    }

    // MARK: Media

    /// Adds a video clip from the bin: at the end of the main track, or as an overlay at the playhead.
    @discardableResult
    public mutating func addVideo(_ asset: E.Asset, overlay: Bool = false) -> Bool {
        guard asset.kind == .video, let d = asset.durationSec, d >= E.minClipSourceSec else { return false }
        var newId: String?
        let at = playhead
        let ok = apply { p in
            var q = p.addingAsset(asset)
            let id = q.newId("c")
            if !overlay, let main = q.mainTrack {
                newId = id
                return q.adding(.video(E.VideoClip(id: id, asset: asset.id, inSec: 0, outSec: E.r6(d))), toTrack: main.id)
            }
            let len = min(d, max(E.minClipSourceSec, E.durationSec(q) - at))
            let clip = E.VideoClip(id: id, asset: asset.id, inSec: 0, outSec: E.r6(len), startSec: E.r6(at), fit: .contain,
                                   transform: E.Transform(x: 0.7, y: 0.3, scale: 0.45))
            for t in q.tracks where t.kind == .video {
                if let r = q.adding(.video(clip), toTrack: t.id) { newId = id; return r }
            }
            guard let r = q.addingTrack(.video, name: "Overlay") else { return nil }
            q = r.project
            newId = id
            return q.adding(.video(clip), toTrack: r.trackId)
        }
        if ok { selection = newId }
        return ok
    }

    /// Adds an audio clip (music / voice-over / sound effect) at `at` (default: music at 0, others at the playhead).
    @discardableResult
    /// `trimStart` drops the file's first seconds (a voice-over recorded over playback: the output's delay).
    public mutating func addAudio(_ asset: E.Asset, kind: E.TrackKind, at: Double? = nil, trimStart: Double = 0) -> Bool {
        guard kind.isAudio, asset.kind == .audio || asset.kind == .video, let full = asset.durationSec else { return false }
        let skip = E.r6(max(0, min(trimStart, full - E.minClipSourceSec)))
        let d = full - skip
        guard d >= E.minClipSourceSec else { return false }
        let start = at ?? (kind == .music ? 0 : playhead)
        var newId: String?
        let ok = apply { p in
            var q = p.addingAsset(asset)
            let id = q.newId(kind == .music ? "m" : kind == .voice ? "vo" : "fx")
            let len = min(d, max(E.minClipSourceSec, E.durationSec(q) - start))
            let clip = E.AudioClip(id: id, asset: asset.id, startSec: E.r6(start), inSec: skip, outSec: E.r6(skip + len),
                                   fadeOutSec: kind == .music ? min(1, len / 4) : nil)
            for t in q.tracks where t.kind == kind {
                if let r = q.adding(.audio(clip), toTrack: t.id) { newId = id; return r }
            }
            guard let r = q.addingTrack(kind, name: EditSuiteState.defaultLabel(kind)) else { return nil }
            q = r.project
            newId = id
            return q.adding(.audio(clip), toTrack: r.trackId)
        }
        if ok { selection = newId; tab = .audio }
        return ok
    }

    /// Adds a picture (sticker) at the playhead.
    @discardableResult
    public mutating func addImage(_ asset: E.Asset, durationSec: Double = 3) -> Bool {
        guard asset.kind == .image else { return false }
        var newId: String?
        let at = playhead
        let ok = apply { p in
            var q = p.addingAsset(asset)
            let id = q.newId("img")
            let d = min(durationSec, max(E.minItemSec, E.durationSec(q) - at))
            let item = E.ImageItem(id: id, asset: asset.id, startSec: E.r6(at), durationSec: E.r6(d), transform: E.Transform(x: 0.5, y: 0.4, scale: 0.4),
                                   animIn: E.Anim(kind: .pop, durationSec: 0.3))
            for t in q.tracks where t.kind == .image {
                if let r = q.adding(.image(item), toTrack: t.id) { newId = id; return r }
            }
            guard let r = q.addingTrack(.image, name: "Stickers") else { return nil }
            q = r.project
            newId = id
            return q.adding(.image(item), toTrack: r.trackId)
        }
        if ok { selection = newId }
        return ok
    }

    // MARK: Audio

    /// Changes the selected clip's sound fields (video clip or audio clip).
    @discardableResult
    public mutating func changeSound(_ change: @escaping (inout EditSuite.Sound) -> Void) -> Bool {
        changeSelected { it in
            switch it {
            case .video(var c):
                var s = EditSuite.Sound(volume: c.volume, muted: c.muted, fadeInSec: c.fadeInSec, fadeOutSec: c.fadeOutSec, voiceEffect: c.voiceEffect,
                                        enhance: c.enhance, audioAsset: c.audioAsset)
                change(&s)
                c.volume = s.volume; c.muted = s.muted; c.fadeInSec = s.fadeInSec; c.fadeOutSec = s.fadeOutSec; c.voiceEffect = s.voiceEffect
                c.enhance = s.enhance; c.audioAsset = s.audioAsset
                it = .video(c)
            case .audio(var c):
                var s = EditSuite.Sound(volume: c.volume, muted: c.muted, fadeInSec: c.fadeInSec, fadeOutSec: c.fadeOutSec, voiceEffect: c.voiceEffect,
                                        enhance: c.enhance, audioAsset: nil)
                change(&s)
                c.volume = s.volume; c.muted = s.muted; c.fadeInSec = s.fadeInSec; c.fadeOutSec = s.fadeOutSec; c.voiceEffect = s.voiceEffect
                c.enhance = s.enhance
                it = .audio(c)
            default: break
            }
        }
    }

    public var selectedSound: EditSuite.Sound? {
        switch selectedItem {
        case .video(let c): return EditSuite.Sound(volume: c.volume, muted: c.muted, fadeInSec: c.fadeInSec, fadeOutSec: c.fadeOutSec,
                                                   voiceEffect: c.voiceEffect, enhance: c.enhance, audioAsset: c.audioAsset)
        case .audio(let c): return EditSuite.Sound(volume: c.volume, muted: c.muted, fadeInSec: c.fadeInSec, fadeOutSec: c.fadeOutSec,
                                                   voiceEffect: c.voiceEffect, enhance: c.enhance, audioAsset: nil)
        default: return nil
        }
    }

    /// The first music track (for Audio · mix & beats).
    public var musicTrack: E.Track? { project.tracks.first { $0.kind == .music } }

    /// Auto-duck on/off for the music under voice and speech (−12 dB, attack 0.2 s, release 0.6 s by default).
    @discardableResult
    public mutating func setAutoDuck(_ on: Bool) -> Bool {
        changeDuck { d in d = on ? (d ?? E.Duck(level: EditSuite.gain(db: -12), attackSec: 0.2, releaseSec: 0.6, under: [.voice, .speech])) : nil }
    }

    @discardableResult
    public mutating func changeDuck(_ change: @escaping (inout E.Duck?) -> Void) -> Bool {
        apply { p in
            guard let i = p.tracks.firstIndex(where: { $0.kind == .music }) else { return nil }
            var q = p
            change(&q.tracks[i].duck)
            return q
        }
    }

    /// Beat marks from the beats job on a music clip (source seconds).
    @discardableResult
    public mutating func setBeats(_ itemId: String, beats: [Double], strong: [Double]) -> Bool {
        apply { p in
            p.updating(itemId) { it in
                guard case .audio(var c) = it else { return }
                c.beats = Array(beats.prefix(2000)).filter { $0 >= 0 }
                c.strongBeats = Array(strong.prefix(2000)).filter { $0 >= 0 }
                it = .audio(c)
            }
        }
    }

    // MARK: Shape

    /// Changes the canvas shape (keeps the resolution class). `framing` = each main clip's horizontal centre (0–1 of the
    /// source) to keep in view, from face detection in the app; clips are moved so that point is centred when it can be.
    /// Owner bug (build 597): a 16:9 → 9:16 → 16:9 round trip left each clip's x where 9:16 put it (s44 0.667 → 1.181, never
    /// back), so the picture slid off the canvas. Switching straight back now restores the canvas and every clip's transform
    /// exactly; otherwise a clip's x is kept inside the range that shows no edge for the new shape (its scale counted).
    @discardableResult
    public mutating func setRatio(_ r: EditSuite.Ratio, framing: [String: Double] = [:]) -> Bool {
        let fromRatio = export.ratio
        // The canvas keeps its own resolution (run 604: a 1920×1080 edit opened over a 432×768 take came back 1280×720,
        // because the export setting still held the first project's class).
        let size = r.canvas(shortSide: min(project.canvas.width, project.canvas.height))
        // Straight back to the shape before the last switch, nothing else changed: exactly as it was.
        if restoresShape(r), let m = shapeReturn {
            export.ratio = r
            let ok = apply { p in
                var q = p
                q.canvas = m.canvas
                if let mi = q.tracks.firstIndex(where: { $0.kind == .main }) {
                    q.tracks[mi].items = q.tracks[mi].items.map { it in
                        guard case .video(var c) = it, let tf = m.transforms[c.id] else { return it }
                        c.transform = tf
                        return .video(c)
                    }
                }
                return q == p ? nil : q
            }
            shapeReturn = nil
            return ok
        }
        let before = project
        export.ratio = r
        let ok = apply { p in
            var q = p
            q.canvas.width = size.width
            q.canvas.height = size.height
            if let mi = q.tracks.firstIndex(where: { $0.kind == .main }) {
                q.tracks[mi].items = q.tracks[mi].items.map { it in
                    guard case .video(var c) = it, let a = q.asset(c.asset), let w = a.width, let h = a.height else { return it }
                    let (fw, _) = E.fittedSize(width: Double(w), height: Double(h), crop: c.crop, fit: c.fit ?? .cover,
                                               canvasWidth: Double(size.width), canvasHeight: Double(size.height))
                    let over = fw * (c.transform?.scale ?? 1) / Double(size.width)   // drawn width in canvas widths
                    guard over > 0.9999 else { return it }   // narrower than the canvas (contain, scaled down): left as placed
                    let lim = max(0, (over - 1) / 2)
                    var tf = c.transform ?? E.Transform()
                    if let fx = framing[c.id], over > 1.0001 {
                        // centre x so that source point fx sits in the middle, without showing an edge.
                        tf.x = E.r6(min(0.5 + lim, max(0.5 - lim, 0.5 + (0.5 - fx) * over)))
                    } else if let x = tf.x {
                        // No face to follow: only kept inside the range that shows no edge.
                        let kept = E.r6(min(0.5 + lim, max(0.5 - lim, x)))
                        tf.x = kept == 0.5 ? nil : kept
                    } else {
                        return it
                    }
                    c.transform = tf == E.Transform() ? nil : tf
                    return .video(c)
                }
            }
            return q == p ? nil : q
        }
        if ok {
            var keep: [String: E.Transform?] = [:]
            for c in before.mainClips { keep[c.id] = .some(c.transform) }
            shapeReturn = ShapeReturn(from: EditSuite.Ratio.nearest(width: before.canvas.width, height: before.canvas.height),
                                      canvas: before.canvas, transforms: keep, after: project)
        } else {
            export.ratio = fromRatio
        }
        return ok
    }

    /// The last shape switch: what to put back when the next switch returns to the shape before it.
    /// Switching to `r` puts the last switch back exactly (no face framing needed).
    public func restoresShape(_ r: EditSuite.Ratio) -> Bool {
        guard let m = shapeReturn else { return false }
        return m.from == r && m.after == project
    }

    public struct ShapeReturn: Sendable {
        var from: EditSuite.Ratio
        var canvas: E.Canvas
        var transforms: [String: E.Transform?]
        var after: E.Project
    }
}

extension EditSuite {
    /// The visual fields the inspector edits on video, image (and, for transform/keyframes, text) items.
    public struct Visual: Hashable, Sendable {
        public var adjust: EditV2.Adjust?
        public var look: EditV2.Look?
        public var mask: EditV2.Mask?
        public var chroma: EditV2.Chroma?
        public var transform: EditV2.Transform?
        public var opacity: Double?
        public var keyframes: EditV2.Keyframes?
        /// Video and picture items (nil on text).
        public var crop: EditV2.Crop? = nil
    }

    /// The sound fields of a clip.
    public struct Sound: Hashable, Sendable {
        public var volume: Double?
        public var muted: Bool?
        public var fadeInSec: Double?
        public var fadeOutSec: Double?
        public var voiceEffect: EditV2.VoiceEffect?
        public var enhance: Bool?
        public var audioAsset: String?
    }

    /// dB → gain (10^(dB/20)), as the duck level.
    public static func gain(db: Double) -> Double { EditV2.r6(pow(10, db / 20)) }
    /// gain → dB, rounded.
    public static func db(gain: Double) -> Double { (20 * log10(max(1e-6, gain))).rounded() }
}

extension EditV2.Project {
    /// Gives main clips that share an id (applyCuts names pieces `<id>.2`… again on a second pass) fresh ids.
    func uniquingMainIds() -> EditV2.Project {
        guard let mi = tracks.firstIndex(where: { $0.kind == .main }) else { return self }
        var q = self
        var seen = Set<String>()
        for t in q.tracks where t.kind != .main { seen.formUnion(t.items.map(\.id)); seen.insert(t.id) }
        seen.formUnion(q.assets.map(\.id))
        seen.insert(q.tracks[mi].id)
        for i in q.tracks[mi].items.indices {
            var id = q.tracks[mi].items[i].id
            if seen.contains(id) {
                let base = id
                var n = 2
                while seen.contains("\(base).\(n)") || q.allIds.contains("\(base).\(n)") { n += 1 }
                id = "\(base).\(n)"
                q.tracks[mi].items[i].id = id
            }
            seen.insert(id)
        }
        return q
    }

    /// Moves every non-main item starting at or after `t` by `delta` on the chosen tracks (or all but `except`).
    func shiftingItems(after t: Double, by delta: Double, only: Set<String>? = nil, except: Set<String> = []) -> EditV2.Project {
        var q = self
        for i in q.tracks.indices where q.tracks[i].kind != .main && q.tracks[i].kind != .caption {
            if let only, !only.contains(q.tracks[i].id) { continue }
            if except.contains(q.tracks[i].id) { continue }
            q.tracks[i].items = q.tracks[i].items.map { it in
                guard it.startSec >= t - 1e-9 else { return it }
                var x = it
                x.startSec = EditV2.r6(Swift.max(0, it.startSec + delta))
                return x
            }
        }
        return q
    }

    /// No overlaps on a non-main track (sorted order).
    func overlapFree(trackIndex ti: Int) -> Bool {
        let t = tracks[ti]
        if t.kind == .main { return true }
        var prevEnd = -Double.infinity
        for it in t.items {
            if it.startSec < prevEnd - EditV2.overlapSlackSec { return false }
            prevEnd = it.startSec + it.lengthSec
        }
        return true
    }

    /// Sets the transition into a main clip, shortening the duration to what fits (at least 0.1 s); nil kind = a cut.
    public func settingTransitionFitted(_ itemId: String, _ kind: EditV2.TransitionKind?, duration: Double) -> EditV2.Project? {
        guard let kind else { return settingTransition(itemId, nil) }
        guard let (ti, ii) = locate(itemId), tracks[ti].kind == .main, ii > 0, let c = tracks[ti].items[ii].videoClip else { return nil }
        let fit = Swift.min(EditV2.maxTransitionSec, EditV2.clipLength(c) / 2, tracks[ti].items[ii - 1].lengthSec / 2)
        let d = EditV2.r6(Swift.min(Swift.max(EditV2.minTransitionSec, duration), fit))
        guard d >= EditV2.minTransitionSec - 1e-9 else { return nil }
        return settingTransition(itemId, EditV2.Transition(kind: kind, durationSec: d))
    }

    /// Splits a non-main item at timeline t: both parts at least 0.05 s (clips: 0.1 s of source). The second part gets a
    /// new id; text and pictures keep their look, clips their source times.
    public func splittingItem(_ itemId: String, at t: Double) -> (project: EditV2.Project, newId: String)? {
        guard let (ti, ii) = locate(itemId), tracks[ti].kind != .main else { return nil }
        let it = tracks[ti].items[ii]
        let start = it.startSec, len = it.lengthSec
        let local = t - start
        guard local >= EditV2.minItemSec - 1e-9, len - local >= EditV2.minItemSec - 1e-9 else { return nil }
        let nid = newId(itemId + ".")
        var a = it, b = it
        switch it {
        case .video(var c):
            let src = EditV2.r6(EditV2.clipSourceAt(c, local))
            guard src - c.inSec >= EditV2.minClipSourceSec - 1e-9, c.outSec - src >= EditV2.minClipSourceSec - 1e-9 else { return nil }
            var d = c
            c.outSec = src; c.fadeOutSec = nil
            d.id = nid; d.inSec = src; d.startSec = EditV2.r6(t); d.fadeInSec = nil
            c.keyframes = nil; d.keyframes = nil
            a = .video(c); b = .video(d)
        case .audio(var c):
            let src = EditV2.r6(c.inSec + local * (c.speed ?? 1))
            guard src - c.inSec >= EditV2.minClipSourceSec - 1e-9, c.outSec - src >= EditV2.minClipSourceSec - 1e-9 else { return nil }
            var d = c
            c.outSec = src; c.fadeOutSec = nil
            d.id = nid; d.inSec = src; d.startSec = EditV2.r6(t); d.fadeInSec = nil
            c.keyframes = nil; d.keyframes = nil
            a = .audio(c); b = .audio(d)
        case .text(var c):
            var d = c
            c.durationSec = EditV2.r6(local); c.animOut = nil
            d.id = nid; d.startSec = EditV2.r6(t); d.durationSec = EditV2.r6(len - local); d.animIn = nil
            c.keyframes = nil; d.keyframes = nil
            a = .text(c); b = .text(d)
        case .image(var c):
            var d = c
            c.durationSec = EditV2.r6(local); c.animOut = nil
            d.id = nid; d.startSec = EditV2.r6(t); d.durationSec = EditV2.r6(len - local); d.animIn = nil
            c.keyframes = nil; d.keyframes = nil
            a = .image(c); b = .image(d)
        case .adjust(var c):
            var d = c
            c.durationSec = EditV2.r6(local)
            d.id = nid; d.startSec = EditV2.r6(t); d.durationSec = EditV2.r6(len - local)
            c.keyframes = nil; d.keyframes = nil
            a = .adjust(c); b = .adjust(d)
        }
        var p = self
        p.tracks[ti].items.replaceSubrange(ii...ii, with: [a, b])
        return (p, nid)
    }
}
