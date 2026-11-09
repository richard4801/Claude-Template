import Foundation

// Ports of the reference functions (server/api/src/editor/model.ts): easing, keyframes, the timeline, v1 <-> v2, cuts,
// captions, transitions and in/out animations. Same rounding as the reference (r6 = JavaScript's Math.round to 1e-6).

extension EditV2 {
    public static let maxJsonBytes = 256 * 1024
    /// Wave 1: a freeze frame lasts 0.1–30 s.
    public static let holdMinSec = 0.1, holdMaxSec = 30.0
    public static let maxTracks = 16, maxItemsPerTrack = 300, maxItems = 600, maxAssets = 60, maxWords = 3000, maxKeyframes = 100
    public static let minClipSourceSec = 0.1, minItemSec = 0.05, minOutputSec = 0.5, maxOutputSec = 600.0
    public static let minSpeed = 0.1, maxSpeed = 10.0, endSlackSec = 0.05, minTransitionSec = 0.1, maxTransitionSec = 2.0
    /// Speed curves render as this many equal source pieces (each at the curve's speed at its middle).
    public static let curvePieces = 48
    /// Speed-curve presets (x = position in the clip's kept source, speed ×).
    public static let speedPresets: [SpeedPreset: [[Double]]] = [
        .montage: [[0, 1], [0.2, 4], [0.4, 0.5], [0.6, 4], [0.8, 0.5], [1, 1]],
        .hero: [[0, 1], [0.3, 1], [0.42, 6], [0.58, 6], [0.7, 1], [1, 1]],
        .bullet: [[0, 4], [0.35, 4], [0.45, 0.2], [0.55, 0.2], [0.65, 4], [1, 4]],
        .flashIn: [[0, 6], [0.4, 6], [0.6, 1], [1, 1]],
        .flashOut: [[0, 1], [0.4, 1], [0.6, 6], [1, 6]],
    ]
    /// The preset's curve (nil for custom).
    public static func speedCurve(_ preset: SpeedPreset) -> SpeedCurve? { speedPresets[preset].map { SpeedCurve(preset: preset, points: $0) } }
    public static let maxText = 500, overlapSlackSec = 0.001
    public static let v1Speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// Caption paging constants.
    public static let captionGapSec = 0.6, captionTailSec = 0.4, speechJoinSec = 0.4

    // MARK: Numbers as the reference rounds them

    /// JavaScript's Math.round (halves go up, also for negatives).
    static func jsRound(_ v: Double) -> Double {
        guard v.isFinite else { return v }
        let f = v.rounded(.down)
        return v - f >= 0.5 ? f + 1 : f
    }
    static func r6(_ v: Double) -> Double { jsRound(v * 1e6) / 1e6 }
    static func r3(_ v: Double) -> Double { jsRound(v * 1000) / 1000 }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    /// A stable sort (the reference relies on JavaScript's stable Array.sort).
    static func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
        a.enumerated().sorted { x, y in
            if less(x.element, y.element) { return true }
            if less(y.element, x.element) { return false }
            return x.offset < y.offset
        }.map(\.element)
    }

    // MARK: Easing and keyframes

    public static func ease(_ kind: Ease?, _ p: Double) -> Double {
        let p = clamp(p, 0, 1)
        switch kind ?? .linear {
        case .easeIn: return p * p
        case .easeOut: return 1 - (1 - p) * (1 - p)
        case .easeInOut: return p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        case .hold: return 0
        case .linear: return p
        }
    }

    /// The value of a keyframed property at item-local t (keys sorted by t); NaN without keys.
    public static func keyframeValue(_ keys: [Keyframe], _ t: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return .nan }
        if t <= first.t { return first.v }
        if t >= last.t { return last.v }
        for k in 0..<(keys.count - 1) {
            let a = keys[k], b = keys[k + 1]
            if t >= a.t && t < b.t {
                let span = b.t - a.t
                if span <= 0 { return b.v }
                return a.v + (b.v - a.v) * ease(a.ease, (t - a.t) / span)
            }
        }
        return last.v
    }

    /// A property at item-local t: its keyframes when it has any, else the static value.
    /// The item's adjust at item-local `t`: each keyed colour property at its keyframes' value there (model.ts adjustAt).
    /// Unchanged when no colour property is keyed; a keyed property without a static value appears with the curve's value.
    public static func adjustAt(_ adjust: Adjust?, _ keyframes: Keyframes?, _ t: Double) -> Adjust? {
        let keyed = KfProp.color.filter { !(keyframes?[$0] ?? []).isEmpty }
        guard !keyed.isEmpty else { return adjust }
        var out = adjust ?? Adjust()
        for p in keyed { out[p] = r6(propAt(keyframes, p, fallback: adjust?[p] ?? 0, t)) }
        return out
    }

    /// Whether any colour property is keyed (the matrix then changes over time).
    public static func hasColorKeys(_ keyframes: Keyframes?) -> Bool { KfProp.color.contains { !(keyframes?[$0] ?? []).isEmpty } }

    public static func propAt(_ keyframes: Keyframes?, _ prop: KfProp, fallback: Double, _ t: Double) -> Double {
        if let k = keyframes?[prop], !k.isEmpty { return keyframeValue(k, t) }
        return fallback
    }

    // MARK: Timeline

    public static func clipLength(_ c: VideoClip) -> Double {
        if let h = c.holdSec { return h }   // wave 1: a freeze frame lasts holdSec whatever its source range
        if c.speedCurve != nil { return speedPieces(c).reduce(0) { $0 + ($1.outSec - $1.inSec) / $1.speed } }
        return (c.outSec - c.inSec) / c.speed
    }

    // MARK: Speed curves

    /// Speed at x (0–1) of a curve: smoothstep between points in log speed.
    public static func curveSpeed(_ c: SpeedCurve, _ x: Double) -> Double {
        let pts = c.points.filter { $0.count >= 2 }
        guard let first = pts.first, let last = pts.last else { return 1 }
        if x <= first[0] { return first[1] }
        for k in 0..<(pts.count - 1) {
            let a = pts[k], b = pts[k + 1]
            if x <= b[0] {
                let t = b[0] > a[0] ? (x - a[0]) / (b[0] - a[0]) : 1, e = t * t * (3 - 2 * t)
                return exp(log(a[1]) + (log(b[1]) - log(a[1])) * e)
            }
        }
        return last[1]
    }

    /// A constant-speed stretch of a clip's source.
    public struct Piece: Codable, Hashable, Sendable {
        public var inSec: Double
        public var outSec: Double
        public var speed: Double
        public init(inSec: Double, outSec: Double, speed: Double) { self.inSec = inSec; self.outSec = outSec; self.speed = speed }
        public var length: Double { (outSec - inSec) / speed }
    }

    /// A clip as constant-speed pieces: one piece, or `curvePieces` equal source pieces of its speed curve (each at the
    /// curve's speed at its middle). Engines render these.
    public static func speedPieces(inSec: Double, outSec: Double, speed: Double, curve: SpeedCurve?) -> [Piece] {
        guard let curve else { return [Piece(inSec: inSec, outSec: outSec, speed: speed)] }
        let n = curvePieces, len = (outSec - inSec) / Double(n)
        var out: [Piece] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let a: Double = inSec + Double(i) * len
            let b: Double = i == n - 1 ? outSec : inSec + Double(i + 1) * len
            let x: Double = (Double(i) + 0.5) / Double(n)
            out.append(Piece(inSec: r6(a), outSec: r6(b), speed: r6(curveSpeed(curve, x))))
        }
        return out
    }
    public static func speedPieces(_ c: VideoClip) -> [Piece] {
        if c.holdSec != nil { return [Piece(inSec: c.inSec, outSec: c.inSec, speed: 1)] }   // wave 1: a hold is one frame
        return speedPieces(inSec: c.inSec, outSec: c.outSec, speed: c.speed, curve: c.speedCurve)
    }

    /// Seconds from the clip's start on the timeline at source time `sec` (clamped to the clip).
    public static func clipTimeAt(_ c: VideoClip, _ sec: Double) -> Double {
        if c.holdSec != nil { return 0 }
        var acc = 0.0
        for p in speedPieces(c) {
            if sec <= p.outSec { return acc + max(0, sec - p.inSec) / p.speed }
            acc += (p.outSec - p.inSec) / p.speed
        }
        return acc
    }

    /// The source time at `local` seconds from the clip's start on the timeline (the inverse of clipTimeAt).
    public static func clipSourceAt(_ c: VideoClip, _ local: Double) -> Double {
        if c.holdSec != nil { return c.inSec }
        var acc = 0.0
        for p in speedPieces(c) {
            let len = (p.outSec - p.inSec) / p.speed
            if local <= acc + len { return p.inSec + max(0, local - acc) * p.speed }
            acc += len
        }
        return c.outSec
    }

    /// A curve cut down to the source range [x0, x1] of its clip, rescaled to 0–1 (preset becomes custom).
    public static func subCurve(_ c: SpeedCurve, _ x0: Double, _ x1: Double) -> SpeedCurve {
        let inner = c.points.filter { $0.count >= 2 && $0[0] > x0 + 1e-9 && $0[0] < x1 - 1e-9 }.map { [r6(($0[0] - x0) / (x1 - x0)), $0[1]] }
        return SpeedCurve(preset: .custom, points: [[0, r6(curveSpeed(c, x0))]] + inner + [[1, r6(curveSpeed(c, x1))]])
    }
    public static func clipLength(_ c: AudioClip) -> Double { (c.outSec - c.inSec) / (c.speed ?? 1) }

    public struct MainSpan: Codable, Hashable, Sendable {
        public var id: String
        public var index: Int
        public var startSec: Double
        public var endSec: Double
        public var transitionSec: Double
    }

    /// Each main clip's place on the timeline. A clip with transitionIn starts that much before the previous clip ends.
    public static func timeline(_ p: Project) -> [MainSpan] {
        var out: [MainSpan] = []
        var end = 0.0
        for (i, c) in p.mainClips.enumerated() {
            let tr = i > 0 ? (c.transitionIn?.durationSec ?? 0) : 0
            let start = max(0, end - tr)
            let len = clipLength(c)
            out.append(MainSpan(id: c.id, index: i, startSec: r6(start), endSec: r6(start + len), transitionSec: tr))
            end = start + len
        }
        return out
    }

    public static func durationSec(_ p: Project) -> Double { timeline(p).last?.endSec ?? 0 }

    /// Timeline start/end of any item (main clips through timeline(); others from startSec).
    public static func itemSpan(_ p: Project, _ track: Track, _ item: Item) -> SecRange {
        if track.kind == .main {
            let s = timeline(p).first { $0.id == item.id }
            return SecRange(startSec: s?.startSec ?? 0, endSec: s?.endSec ?? 0)
        }
        let start = item.startSec
        return SecRange(startSec: r6(start), endSec: r6(start + item.lengthSec))
    }

    // MARK: v1 <-> v2

    public static func fromV1(_ v1: EditListV1, _ info: SourceFacts) -> Project {
        let asset = Asset(id: "src", kind: .video, take: v1.sourceTakeId, durationSec: v1.sourceDurationSec, width: info.width, height: info.height,
                          hasAudio: info.hasAudio ?? true)
        let items: [Item] = v1.segments.enumerated().map { i, s in
            .video(VideoClip(id: "c\(i + 1)", asset: "src", inSec: s.inSec, outSec: s.outSec, speed: s.speed, muted: s.muted == true ? true : nil))
        }
        return Project(sourceTakeId: v1.sourceTakeId, canvas: Canvas(width: info.width, height: info.height, fps: info.fps, background: "#000000"),
                       assets: [asset], tracks: [Track(id: "main", kind: .main, items: items)], mute: v1.mute ? true : nil)
    }

    /// From the editor's v1 working copy.
    public static func fromV1(_ list: EditList, _ info: SourceFacts) -> Project { fromV1(EditListV1(list), info) }

    /// The v1 edit list for a project that only uses v1 features (one source, main track only, v1 speeds, in order); else nil.
    public static func toV1(_ p: Project) -> EditListV1? {
        guard p.tracks.count == 1, let t = p.tracks.first, t.kind == .main else { return nil }
        if t.muted == true || t.hidden == true || (t.volume != nil && t.volume != 1) { return nil }
        guard let src = p.assets.first(where: { $0.take == p.sourceTakeId && $0.kind == .video }), let srcDur = src.durationSec else { return nil }
        var prev = 0.0
        var segs: [V1Segment] = []
        for item in t.items {
            guard case .video(let it) = item else { return nil }
            if it.asset != src.id || !v1Speeds.contains(it.speed) || it.inSec < prev - 1e-9 { return nil }
            let extra: [Any?] = [it.startSec, it.volume, it.fadeInSec, it.fadeOutSec, it.audioAsset, it.fit, it.transform, it.crop, it.opacity,
                                 it.keyframes, it.filter, it.adjust, it.chroma, it.transitionIn, it.look, it.speedCurve, it.mask, it.voiceEffect, it.enhance, it.alphaMatte]
            if extra.contains(where: { $0 != nil }) { return nil }
            prev = it.outSec
            segs.append(V1Segment(inSec: it.inSec, outSec: it.outSec, speed: it.speed, muted: it.muted == true ? true : nil))
        }
        if segs.count > 50 { return nil }
        return EditListV1(sourceTakeId: p.sourceTakeId, sourceDurationSec: srcDur, segments: segs, mute: p.mute == true)
    }

    /// toV1 as the editor's working copy.
    public static func toV1EditList(_ p: Project) -> EditList? { toV1(p)?.editList }

    // MARK: Cuts (silence / filler removal)

    /// Merges and sorts ranges (joining those closer than `joinGap`).
    public static func mergeRanges(_ rs: [SecRange], joinGap: Double = 0) -> [SecRange] {
        let s = stableSorted(rs.filter { $0.endSec > $0.startSec }) { $0.startSec < $1.startSec }
        var out: [SecRange] = []
        for r in s {
            if let last = out.last, r.startSec <= last.endSec + joinGap { out[out.count - 1].endSec = max(last.endSec, r.endSec) }
            else { out.append(r) }
        }
        return out
    }

    /// Removes source ranges of `assetId` from every main clip of that asset. Clips are split around the cuts; pieces
    /// shorter than 0.1 s of source are dropped; looks and speed carry over; a transition stays only on the first piece of a
    /// clip that kept its start. A split clip's pieces are `<id>`, `<id>.2`, `<id>.3`… Unchanged when every clip would go.
    public static func applyCuts(_ p: Project, assetId: String, cuts: [SecRange]) -> Project {
        let rs = mergeRanges(cuts)
        guard let mi = p.tracks.firstIndex(where: { $0.kind == .main }) else { return p }
        var items: [VideoClip] = []
        for it in p.tracks[mi].items.compactMap(\.videoClip) {
            if it.asset != assetId { items.append(it); continue }
            // A hold (freeze frame) has no source span: it goes when a cut covers its frame, else it stays as it is.
            if it.holdSec != nil {
                if !rs.contains(where: { it.inSec >= $0.startSec && it.inSec < $0.endSec }) { items.append(it) }
                continue
            }
            var pieces = [SecRange(startSec: it.inSec, endSec: it.outSec)]
            for r in rs {
                pieces = pieces.flatMap { pc -> [SecRange] in
                    if r.endSec <= pc.startSec || r.startSec >= pc.endSec { return [pc] }
                    var keep: [SecRange] = []
                    if r.startSec > pc.startSec { keep.append(SecRange(startSec: pc.startSec, endSec: r.startSec)) }
                    if r.endSec < pc.endSec { keep.append(SecRange(startSec: r.endSec, endSec: pc.endSec)) }
                    return keep
                }
            }
            pieces = pieces.filter { $0.endSec - $0.startSec >= minClipSourceSec - 1e-9 }
            for (k, pc) in pieces.enumerated() {
                var c = it
                let keepsStart = k == 0 && abs(pc.startSec - it.inSec) < 1e-9
                c.id = k == 0 ? it.id : "\(it.id).\(k + 1)"
                c.inSec = r6(pc.startSec)
                c.outSec = r6(pc.endSec)
                if !keepsStart { c.transitionIn = nil }
                if let sc = it.speedCurve {
                    let span = it.outSec - it.inSec
                    c.speedCurve = subCurve(sc, (pc.startSec - it.inSec) / span, (pc.endSec - it.inSec) / span)
                }
                items.append(c)
            }
        }
        if items.isEmpty { return p }
        // A transition may now be on the first clip, or longer than its new neighbours allow: drop those.
        let fixed: [VideoClip] = items.enumerated().map { i, c in
            guard let tr = c.transitionIn else { return c }
            let ok = i > 0 && tr.durationSec <= clipLength(c) / 2 + 1e-9 && tr.durationSec <= clipLength(items[i - 1]) / 2 + 1e-9
            if ok { return c }
            var d = c
            d.transitionIn = nil
            return d
        }
        var out = p
        out.tracks[mi].items = fixed.map { .video($0) }
        return out
    }

    // MARK: Captions

    public struct TimedWord: Codable, Hashable, Sendable {
        public var text: String
        public var startSec: Double
        public var endSec: Double
        /// Index into the caption track's words.
        public var index: Int
    }

    /// Caption words on the timeline: each source word mapped through every main clip of the caption asset that keeps its midpoint.
    public static func captionWords(_ p: Project) -> [TimedWord] {
        guard let ct = p.captionTrack else { return [] }
        let spans = timeline(p)
        var out: [TimedWord] = []
        for (i, c) in p.mainClips.enumerated() where c.asset == ct.asset && c.holdSec == nil {   // a hold has no speech
            let s = spans[i]
            for (idx, w) in ct.words.enumerated() {
                let mid = (w.startSec + w.endSec) / 2
                if mid < c.inSec || mid >= c.outSec { continue }
                let a = max(w.startSec, c.inSec), b = min(w.endSec, c.outSec)
                out.append(TimedWord(text: w.text, startSec: r6(s.startSec + clipTimeAt(c, a)), endSec: r6(s.startSec + clipTimeAt(c, b)), index: idx))
            }
        }
        return stableSorted(out) { $0.startSec < $1.startSec || ($0.startSec == $1.startSec && $0.index < $1.index) }
    }

    public struct CaptionPage: Codable, Hashable, Sendable {
        public var startSec: Double
        public var endSec: Double
        public var words: [TimedWord]
    }

    /// Does a word end a sentence (`.`, `!` or `?`, then maybe closing quotes/brackets)?
    static func endsSentence(_ text: String) -> Bool {
        var s = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        while let l = s.last, "\"')]".unicodeScalars.contains(l) { s.removeLast() }
        guard let l = s.last else { return false }
        return l == "." || l == "!" || l == "?"
    }

    public static func captionPages(_ p: Project) -> [CaptionPage] {
        guard let ct = p.captionTrack else { return [] }
        let per = ct.style.preset == .single ? 1 : Int(clamp(jsRound(ct.style.wordsPerPage ?? 3), 1, 8))
        let words = captionWords(p)
        var pages: [[TimedWord]] = []
        var cur: [TimedWord] = []
        for (i, w) in words.enumerated() {
            cur.append(w)
            let next = i + 1 < words.count ? words[i + 1] : nil
            let brk = cur.count >= per || next == nil || next!.startSec - w.endSec > captionGapSec || endsSentence(w.text)
            if brk { pages.append(cur); cur = [] }
        }
        return pages.enumerated().map { i, ws in
            let tail = ws[ws.count - 1].endSec + captionTailSec
            let end = i + 1 < pages.count ? min(pages[i + 1][0].startSec, tail) : tail
            return CaptionPage(startSec: ws[0].startSec, endSec: r6(end), words: ws)
        }
    }

    public struct CaptionPosition: Codable, Hashable, Sendable {
        public var page: Int
        /// The active word, an index into the page's words.
        public var word: Int
    }

    /// The page shown at t and its active word, or nil.
    public static func captionAt(_ p: Project, _ t: Double) -> CaptionPosition? { captionAt(captionPages(p), t) }

    /// captionAt over pages already worked out (the renderer asks once per frame).
    public static func captionAt(_ pages: [CaptionPage], _ t: Double) -> CaptionPosition? {
        for (i, pg) in pages.enumerated() where t >= pg.startSec && t < pg.endSec {
            var w = 0
            for (k, x) in pg.words.enumerated() where x.startSec <= t { w = k }
            return CaptionPosition(page: i, word: w)
        }
        return nil
    }

    // MARK: Transitions and animations

    public struct LayerState: Codable, Hashable, Sendable {
        public var opacity: Double = 1
        public var dx: Double = 0
        public var dy: Double = 0
        public var scale: Double = 1
        /// Degrees clockwise.
        public var rotation: Double = 0
        /// 0–1: motion blur along the move, up to 4 % of the canvas.
        public var blur: Double = 0
        /// 0–1: red/blue offset up to 2 % of the canvas.
        public var rgbSplit: Double = 0
        public init(opacity: Double = 1, dx: Double = 0, dy: Double = 0, scale: Double = 1, rotation: Double = 0, blur: Double = 0, rgbSplit: Double = 0) {
            self.opacity = opacity; self.dx = dx; self.dy = dy; self.scale = scale; self.rotation = rotation; self.blur = blur; self.rgbSplit = rgbSplit
        }
    }

    public struct TransitionState: Codable, Hashable, Sendable {
        /// Outgoing clip.
        public var a: LayerState
        /// Incoming clip (drawn on top).
        public var b: LayerState
        /// The colour dipped through (black / white), or nil.
        public var color: String?
    }

    public static func transitionState(_ kind: TransitionKind, _ p: Double) -> TransitionState {
        let p = clamp(p, 0, 1)
        let e = ease(.easeInOut, p)
        let e3 = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2, peak = sin(Double.pi * p)
        func jit(_ seed: Int) -> Double { (hash01(Int((p * 24).rounded(.down)), seed, 7) - 0.5) * 2 }
        typealias L = LayerState
        switch kind {
        case .fade: return TransitionState(a: L(), b: L(opacity: p), color: nil)
        case .black, .white:
            return TransitionState(a: L(opacity: max(0, 1 - 2 * p)), b: L(opacity: max(0, 2 * p - 1)), color: kind == .black ? "#000000" : "#FFFFFF")
        case .slideLeft: return TransitionState(a: L(dx: -e), b: L(dx: 1 - e), color: nil)
        case .slideRight: return TransitionState(a: L(dx: e), b: L(dx: -(1 - e)), color: nil)
        case .slideUp: return TransitionState(a: L(dy: -e), b: L(dy: 1 - e), color: nil)
        case .slideDown: return TransitionState(a: L(dy: e), b: L(dy: -(1 - e)), color: nil)
        case .zoom: return TransitionState(a: L(opacity: 1 - p, scale: 1 + 0.25 * e), b: L(opacity: p), color: nil)
        case .whip: return TransitionState(a: L(dx: -e3, blur: peak), b: L(dx: 1 - e3, blur: peak), color: nil)
        case .spin:
            return TransitionState(a: L(opacity: p < 0.5 ? 1 : 0, scale: 1 - 0.6 * e, rotation: 180 * e),
                                   b: L(opacity: p < 0.5 ? 0 : 1, scale: 0.4 + 0.6 * e, rotation: -180 * (1 - e)), color: nil)
        case .glitch:
            return TransitionState(a: L(opacity: p < 0.5 ? 1 : 0, dx: 0.04 * peak * jit(1), rgbSplit: peak),
                                   b: L(opacity: p < 0.5 ? 0 : 1, dx: 0.04 * peak * jit(2), rgbSplit: peak), color: nil)

        }
    }

    public struct AnimState: Codable, Hashable, Sendable {
        public var opacity: Double
        public var scale: Double
        public var dy: Double
        /// How many characters a typewriter shows, else nil.
        public var chars: Int?
    }

    /// In/out animation of an image or text item at item-local t.
    public static func animState(durationSec: Double, animIn: Anim?, animOut: Anim?, text: String?, _ t: Double) -> AnimState {
        var opacity = 1.0, scale = 1.0, dy = 0.0
        var chars: Int?
        let n = text.map { $0.unicodeScalars.count } ?? 0
        func apply(_ a: Anim?, _ p: Double) {
            guard let a, a.kind != .none else { return }
            let e = ease(.easeOut, p)
            switch a.kind {
            case .fade: opacity *= e
            case .pop: opacity *= e; scale *= p < 0.7 ? 0.6 + (1.08 - 0.6) * (p / 0.7) : 1.08 + (1 - 1.08) * ((p - 0.7) / 0.3)
            case .slideUp: opacity *= e; dy += 0.05 * (1 - e)
            case .slideDown: opacity *= e; dy -= 0.05 * (1 - e)
            case .zoom: opacity *= e; scale *= 1.3 + (1 - 1.3) * e
            case .typewriter: chars = min(chars ?? n, Int((clamp(p, 0, 1) * Double(n)).rounded(.up)))
            case .none: break
            }
        }
        if let a = animIn { apply(a, a.durationSec > 0 ? clamp(t / a.durationSec, 0, 1) : 1) }
        if let a = animOut { apply(a, a.durationSec > 0 ? clamp((durationSec - t) / a.durationSec, 0, 1) : 1) }
        return AnimState(opacity: r6(opacity), scale: r6(scale), dy: r6(dy), chars: chars)
    }

    public static func animState(_ item: ImageItem, _ t: Double) -> AnimState {
        animState(durationSec: item.durationSec, animIn: item.animIn, animOut: item.animOut, text: nil, t)
    }

    public static func animState(_ item: TextItem, _ t: Double) -> AnimState {
        animState(durationSec: item.durationSec, animIn: item.animIn, animOut: item.animOut, text: item.text, t)
    }
}
