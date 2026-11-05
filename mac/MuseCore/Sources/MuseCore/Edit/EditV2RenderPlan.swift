import Foundation

// The render plan: everything the AVFoundation engine (Muse/App/Edit) needs to lay a v2 project into an
// AVMutableComposition and draw each frame, worked out here without AVFoundation so it is unit-tested on any platform.
// Main clips alternate between two video lanes (A/B) so transitions can overlap them; each overlay video track gets its
// own lane; every sounding clip gets an audio lane with its gain envelope (EditV2.audioEnvelope).

extension EditV2 {
    /// What the engine read from a source file.
    public struct MediaInfo: Hashable, Sendable {
        public var durationSec: Double
        public var hasVideo: Bool
        public var hasAudio: Bool
        /// Upright display size (after the file's rotation); 0 when unknown.
        public var width: Int
        public var height: Int
        public init(durationSec: Double, hasVideo: Bool, hasAudio: Bool, width: Int = 0, height: Int = 0) {
            self.durationSec = durationSec; self.hasVideo = hasVideo; self.hasAudio = hasAudio; self.width = width; self.height = height
        }
    }

    public struct VideoSegment: Hashable, Sendable {
        public var trackId: String
        public var itemId: String
        public var assetId: String
        /// Composition video lane: 0/1 = main A/B, 2… = overlay video tracks.
        public var lane: Int
        /// Main clip index, nil for overlays.
        public var mainIndex: Int?
        /// Draw order (higher on top): main 0, overlays their track index.
        public var layer: Int
        public var timelineStart: Double
        public var timelineEnd: Double
        public var sourceStart: Double
        public var sourceEnd: Double
        public var isMain: Bool { mainIndex != nil }
        public var timelineLength: Double { timelineEnd - timelineStart }
        public func contains(_ t: Double) -> Bool { t >= timelineStart - 1e-9 && t < timelineEnd - 1e-9 }
    }

    public struct AudioSegment: Hashable, Sendable {
        public var trackId: String
        public var itemId: String
        /// The asset whose sound plays (a video clip's audioAsset when it has one).
        public var assetId: String
        public var lane: Int
        public var timelineStart: Double
        public var timelineEnd: Double
        public var sourceStart: Double
        public var sourceEnd: Double
        /// Timeline gain points (EditV2.audioEnvelope), clipped to the segment.
        public var envelope: [GainPoint]
    }

    public struct RenderPlan: Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var fps: Double
        public var background: String
        public var durationSec: Double
        /// Main segments first (in order), then overlays by track.
        public var video: [VideoSegment]
        public var audio: [AudioSegment]
        /// Times where the set of playing video segments changes (0 … duration), for the compositor's instructions.
        public var boundaries: [Double]

        /// The video segments that need a frame at t.
        public func videoSegments(at t: Double) -> [VideoSegment] { video.filter { $0.contains(t) } }

        /// The video segments playing anywhere inside [a, b).
        public func videoSegments(from a: Double, to b: Double) -> [VideoSegment] {
            video.filter { $0.timelineStart < b - 1e-9 && $0.timelineEnd > a + 1e-9 }
        }
    }

    /// Lays the project out for rendering. Sources missing from `media` (or without video/sound) are left out; overlays and
    /// sounds past the project's end are cut there; hidden tracks don't draw; silent clips get no audio segment.
    public static func renderPlan(_ p: Project, media: [String: MediaInfo]) -> RenderPlan {
        let d = durationSec(p)
        let spans = timeline(p)
        var video: [VideoSegment] = []
        var audio: [AudioSegment] = []
        var audioLane = 2
        var videoLane = 2

        func sourceRange(_ inSec: Double, _ outSec: Double, _ speed: Double, start: Double, end: Double, asset: String) -> (Double, Double)? {
            let s = inSec + 0
            var e = inSec + (end - start) * speed
            e = min(e, outSec)
            if let m = media[asset], m.durationSec > 0 { e = min(e, m.durationSec) }
            return e - s > 1e-3 ? (s, e) : nil
        }

        func addAudio(_ track: Track, _ itemId: String, asset: String, inSec: Double, outSec: Double, speed: Double, start: Double, end: Double, lane: Int) -> Bool {
            guard media[asset]?.hasAudio == true, let (s, e) = sourceRange(inSec, outSec, speed, start: start, end: end, asset: asset) else { return false }
            let env = audioEnvelope(p, trackId: track.id, itemId: itemId)
            guard env.contains(where: { $0.gain > 0 }) else { return false }
            audio.append(AudioSegment(trackId: track.id, itemId: itemId, assetId: asset, lane: lane, timelineStart: start, timelineEnd: end,
                                      sourceStart: s, sourceEnd: e, envelope: env))
            return true
        }

        for (ti, t) in p.tracks.enumerated() {
            switch t.kind {
            case .main:
                for (i, c) in t.items.compactMap(\.videoClip).enumerated() where i < spans.count {
                    let start = spans[i].startSec, end = min(spans[i].endSec, d)
                    guard end - start > 1e-3 else { continue }
                    if t.hidden != true, media[c.asset]?.hasVideo == true, let (s, e) = sourceRange(c.inSec, c.outSec, c.speed, start: start, end: end, asset: c.asset) {
                        video.append(VideoSegment(trackId: t.id, itemId: c.id, assetId: c.asset, lane: i % 2, mainIndex: i, layer: 0,
                                                  timelineStart: start, timelineEnd: end, sourceStart: s, sourceEnd: e))
                    }
                    _ = addAudio(t, c.id, asset: c.audioAsset ?? c.asset, inSec: c.inSec, outSec: c.outSec, speed: c.speed, start: start, end: end, lane: i % 2)
                }
            case .video:
                let vLane = videoLane, aLane = audioLane
                var usedV = false, usedA = false
                for c in t.items.compactMap(\.videoClip) {
                    let start = r6(c.startSec ?? 0), end = min(r6(start + clipLength(c)), d)
                    guard end - start > 1e-3 else { continue }
                    if t.hidden != true, media[c.asset]?.hasVideo == true, let (s, e) = sourceRange(c.inSec, c.outSec, c.speed, start: start, end: end, asset: c.asset) {
                        video.append(VideoSegment(trackId: t.id, itemId: c.id, assetId: c.asset, lane: vLane, mainIndex: nil, layer: ti,
                                                  timelineStart: start, timelineEnd: end, sourceStart: s, sourceEnd: e))
                        usedV = true
                    }
                    if addAudio(t, c.id, asset: c.audioAsset ?? c.asset, inSec: c.inSec, outSec: c.outSec, speed: c.speed, start: start, end: end, lane: aLane) { usedA = true }
                }
                if usedV { videoLane += 1 }
                if usedA { audioLane += 1 }
            case .music, .voice, .sfx:
                let aLane = audioLane
                var used = false
                for c in t.items.compactMap(\.audioClip) {
                    let start = r6(c.startSec), end = min(r6(start + clipLength(c)), d)
                    guard end - start > 1e-3 else { continue }
                    if addAudio(t, c.id, asset: c.asset, inSec: c.inSec, outSec: c.outSec, speed: c.speed ?? 1, start: start, end: end, lane: aLane) { used = true }
                }
                if used { audioLane += 1 }
            case .image, .text, .caption:
                break
            }
        }

        var cuts = Set<Double>([0, d])
        for v in video { cuts.insert(v.timelineStart); cuts.insert(v.timelineEnd) }
        var boundaries: [Double] = []
        for t in cuts.sorted() where t >= 0 && t <= d {
            if let last = boundaries.last, t - last < 1e-3 { continue }
            boundaries.append(t)
        }
        if let last = boundaries.last, last < d { boundaries[boundaries.count - 1] = d }
        return RenderPlan(width: p.canvas.width, height: p.canvas.height, fps: p.canvas.fps, background: p.canvas.background ?? "#000000",
                          durationSec: d, video: video, audio: audio, boundaries: boundaries)
    }

    // MARK: Per-frame state

    /// How one main clip is drawn at a moment: its segment and its transition layer state.
    public struct MainLayer: Hashable, Sendable {
        public var segment: VideoSegment
        public var state: LayerState
    }

    /// The main track at timeline t: the clips to draw bottom to top (outgoing, then incoming during a transition), and the
    /// colour to fill under them for a dip-to-black/white.
    public static func mainFrame(_ p: Project, plan: RenderPlan, at t: Double) -> (layers: [MainLayer], dip: String?) {
        let main = plan.video.filter { $0.isMain && $0.contains(t) }.sorted { ($0.mainIndex ?? 0) < ($1.mainIndex ?? 0) }
        guard let incoming = main.last else { return ([], nil) }
        let clips = p.mainClips
        guard let idx = incoming.mainIndex, idx < clips.count else { return (main.map { MainLayer(segment: $0, state: LayerState()) }, nil) }
        let spans = timeline(p)
        let tr = idx > 0 ? clips[idx].transitionIn : nil
        let span = spans[idx]
        if let tr, span.transitionSec > 0, t < span.startSec + span.transitionSec {
            let st = transitionState(tr.kind, (t - span.startSec) / span.transitionSec)
            var out: [MainLayer] = []
            if let a = main.first(where: { $0.mainIndex == idx - 1 }) { out.append(MainLayer(segment: a, state: st.a)) }
            out.append(MainLayer(segment: incoming, state: st.b))
            return (out, st.color)
        }
        return ([MainLayer(segment: incoming, state: LayerState())], nil)
    }

    /// Where a visual item is at item-local t: centre (canvas fractions, top-left origin), scale, clockwise rotation in
    /// degrees and opacity, from its transform/opacity, keyframes and (images/text) in/out animation.
    public struct Placement: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var scale: Double
        public var rotation: Double
        public var opacity: Double
        /// Characters a typewriter shows (text), else nil.
        public var chars: Int?
    }

    public static func placement(transform: Transform?, opacity: Double?, keyframes: Keyframes?, anim: AnimState? = nil, _ t: Double) -> Placement {
        let tf = transform ?? Transform()
        var pl = Placement(x: propAt(keyframes, .x, fallback: tf.x ?? 0.5, t), y: propAt(keyframes, .y, fallback: tf.y ?? 0.5, t),
                           scale: propAt(keyframes, .scale, fallback: tf.scale ?? 1, t), rotation: propAt(keyframes, .rotation, fallback: tf.rotation ?? 0, t),
                           opacity: clamp(propAt(keyframes, .opacity, fallback: opacity ?? 1, t), 0, 1), chars: nil)
        if let a = anim {
            pl.opacity *= a.opacity
            pl.scale *= a.scale
            pl.y += a.dy
            pl.chars = a.chars
        }
        return pl
    }

    public static func placement(_ c: VideoClip, local t: Double) -> Placement {
        placement(transform: c.transform, opacity: c.opacity, keyframes: c.keyframes, t)
    }
    public static func placement(_ im: ImageItem, local t: Double) -> Placement {
        placement(transform: im.transform, opacity: im.opacity, keyframes: im.keyframes, anim: animState(im, t), t)
    }
    public static func placement(_ tx: TextItem, local t: Double) -> Placement {
        placement(transform: tx.transform, opacity: tx.opacity, keyframes: tx.keyframes, anim: animState(tx, t), t)
    }

    /// The size (canvas pixels) a picture of `w`×`h` gets at scale 1: after its crop, fitted to the canvas keeping its
    /// aspect (`cover` fills the canvas, `contain` shows all of it).
    public static func fittedSize(width w: Double, height h: Double, crop: Crop?, fit: Fit, canvasWidth cw: Double, canvasHeight ch: Double) -> (Double, Double) {
        let c = crop ?? Crop()
        let vw = w * max(0.1, 1 - (c.left ?? 0) - (c.right ?? 0)), vh = h * max(0.1, 1 - (c.top ?? 0) - (c.bottom ?? 0))
        guard vw > 0, vh > 0 else { return (cw, ch) }
        let k = fit == .cover ? max(cw / vw, ch / vh) : min(cw / vw, ch / vh)
        return (vw * k, vh * k)
    }
}
