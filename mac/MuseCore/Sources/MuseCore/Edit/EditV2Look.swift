import Foundation

// Colour (one 3×4 affine RGB matrix per item), chroma key and audio gain (ducking, envelopes): ports of the reference
// (server/api/src/editor/model.ts) plus the chroma key's per-colour formula that the renderers bake into a colour cube.

extension EditV2 {
    public struct Tint: Codable, Hashable, Sendable {
        public var color: String
        public var strength: Double
        public init(color: String, strength: Double) { self.color = color; self.strength = strength }
    }

    public struct FilterPreset: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var adjust: Adjust
        public var tint: Tint?
        public init(id: String, label: String, adjust: Adjust, tint: Tint? = nil) { self.id = id; self.label = label; self.adjust = adjust; self.tint = tint }
    }

    /// "#RRGGBB" → r, g, b in 0…1 (0 for anything unparsable).
    public static func hexRgb(_ h: String) -> (Double, Double, Double) {
        let n = Int(h.dropFirst(), radix: 16) ?? 0
        return (Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255)
    }

    private static let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]
    /// a ∘ b: apply b first, then a (3×4 row-major affine matrices).
    private static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var o = [Double](repeating: 0, count: 12)
        for i in 0..<3 {
            for j in 0..<4 {
                var s = 0.0
                for k in 0..<3 { s += a[i * 4 + k] * b[k * 4 + j] }
                if j == 3 { s += a[i * 4 + 3] }
                o[i * 4 + j] = s
            }
        }
        return o
    }
    private static let luma: [Double] = [0.2126, 0.7152, 0.0722]

    public struct ResolvedAdjust: Hashable, Sendable {
        public var exposure: Double
        public var contrast: Double
        public var saturation: Double
        public var temperature: Double
    }

    /// The adjust an item ends up with: its own plus amount × the filter preset's (each clamped to ±1), and the tint.
    public static func effectiveAdjust(_ adjust: Adjust?, _ filter: FilterRef?, presets: [FilterPreset] = filters) -> (adjust: ResolvedAdjust, tint: Tint?) {
        var a = ResolvedAdjust(exposure: adjust?.exposure ?? 0, contrast: adjust?.contrast ?? 0, saturation: adjust?.saturation ?? 0,
                               temperature: adjust?.temperature ?? 0)
        var tint: Tint?
        if let filter, let pr = presets.first(where: { $0.id == filter.id }) {
            let k = clamp(filter.amount, 0, 1)
            a.exposure = clamp(a.exposure + k * (pr.adjust.exposure ?? 0), -1, 1)
            a.contrast = clamp(a.contrast + k * (pr.adjust.contrast ?? 0), -1, 1)
            a.saturation = clamp(a.saturation + k * (pr.adjust.saturation ?? 0), -1, 1)
            a.temperature = clamp(a.temperature + k * (pr.adjust.temperature ?? 0), -1, 1)
            if let t = pr.tint, k > 0 { tint = Tint(color: t.color, strength: t.strength * k) }
        }
        return (a, tint)
    }

    /// One 3×4 affine RGB matrix (row-major; out = M · (r, g, b, 1)) for the item's look:
    /// exposure → temperature → tint (green ↔ magenta) → contrast → saturation → preset colour. Apply on sRGB values 0–1, then clamp.
    public static func colorMatrix(_ adjust: Adjust?, _ filter: FilterRef?, presets: [FilterPreset] = filters) -> [Double] {
        let (a, tint) = effectiveAdjust(adjust, filter, presets: presets)
        var m = identity
        let ex = pow(2, a.exposure)
        m = mul([ex, 0, 0, 0, 0, ex, 0, 0, 0, 0, ex, 0], m)
        m = mul([1 + 0.1 * a.temperature, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 - 0.1 * a.temperature, 0], m)
        // Tint (the item's own adjust only; presets don't add it): green ↔ magenta.
        let g = clamp(adjust?.tint ?? 0, -1, 1)
        if g != 0 { m = mul([1 + 0.05 * g, 0, 0, 0, 0, 1 - 0.1 * g, 0, 0, 0, 0, 1 + 0.05 * g, 0], m) }
        let c = 1 + a.contrast, off = 0.5 * (1 - c)
        m = mul([c, 0, 0, off, 0, c, 0, off, 0, 0, c, off], m)
        let s = 1 + a.saturation
        var sat: [Double] = []
        for i in 0..<3 {
            for j in 0..<3 { sat.append((1 - s) * luma[j] + (i == j ? s : 0)) }
            sat.append(0)
        }
        m = mul(sat, m)
        if let tint, tint.strength > 0 {
            let (tr, tg, tb) = hexRgb(tint.color)
            let k = clamp(tint.strength, 0, 1)
            m = mul([1 - k, 0, 0, tr * k, 0, 1 - k, 0, tg * k, 0, 0, 1 - k, tb * k], m)
        }
        return m.map(r6)
    }

    /// Is this matrix the identity (nothing to draw)?
    public static func isIdentity(_ m: [Double]) -> Bool { m.count == 12 && zip(m, identity).allSatisfy { abs($0 - $1) < 1e-9 } }

    // MARK: Chroma key

    /// The chroma key for one sRGB colour (0–1): its alpha and the spill-corrected colour (not premultiplied). Distance in the
    /// Rec.709 YCbCr chroma plane: alpha 0 within `similarity` of the key colour, a smoothstep up to similarity + smoothness;
    /// kept pixels near the key are pulled towards their own luma by `spill`. Renderers bake it into a colour cube.
    public static func chromaKey(_ r: Double, _ g: Double, _ b: Double, _ ck: Chroma) -> (r: Double, g: Double, b: Double, alpha: Double) {
        // The shared formula (plans/video-editor.md "Chroma key"; reference model.ts chromaKey; fixture functions.json → chroma).
        let (kr, kg, kb) = hexRgb(ck.color)
        func cbcr(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double) {
            (-0.168736 * r - 0.331264 * g + 0.5 * b, 0.5 * r - 0.418688 * g - 0.081312 * b)
        }
        let (cb, cr) = cbcr(r, g, b), (kcb, kcr) = cbcr(kr, kg, kb)
        let base = ((cb - kcb) * (cb - kcb) + (cr - kcr) * (cr - kcr)).squareRoot() - (ck.similarity ?? 0.4)
        let alpha = pow(clamp(base / max(ck.smoothness ?? 0.08, 1e-4), 0, 1), 1.5)
        let s = pow(clamp(base / max(ck.spill ?? 0.5, 1e-4), 0, 1), 1.5)
        let l = luma[0] * r + luma[1] * g + luma[2] * b
        return (l + (r - l) * s, l + (g - l) * s, l + (b - l) * s, alpha)
    }

    /// RGBA float data for a colour cube of `size`³ entries (red fastest, then green, then blue), premultiplied, as Core
    /// Image's CIColorCube and a GL 3D LUT want it.
    public static func chromaCube(_ ck: Chroma, size: Int = 32) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(size * size * size * 4)
        let n = Double(size - 1)
        for bi in 0..<size {
            for gi in 0..<size {
                for ri in 0..<size {
                    let k = chromaKey(Double(ri) / n, Double(gi) / n, Double(bi) / n, ck)
                    out += [Float(k.r * k.alpha), Float(k.g * k.alpha), Float(k.b * k.alpha), Float(k.alpha)]
                }
            }
        }
        return out
    }

    // MARK: Audio

    public struct GainPoint: Codable, Hashable, Sendable {
        public var t: Double
        public var gain: Double
        public init(t: Double, gain: Double) { self.t = t; self.gain = gain }
    }

    /// Timeline ranges where speech/voice is heard, for ducking.
    public static func duckRegions(_ p: Project, _ duck: Duck) -> [SecRange] {
        var rs: [SecRange] = []
        if duck.under.contains(.voice) {
            for t in p.tracks where t.kind == .voice && t.muted != true {
                for it in t.items { rs.append(itemSpan(p, t, it)) }
            }
        }
        if duck.under.contains(.speech) {
            for w in captionWords(p) { rs.append(SecRange(startSec: w.startSec, endSec: w.endSec)) }
        }
        return mergeRanges(rs, joinGap: speechJoinSec)
    }

    /// The sound-related fields of a video or audio clip.
    private struct Sound {
        var id: String
        var volume: Double?
        var muted: Bool?
        var fadeInSec: Double?
        var fadeOutSec: Double?
        var keyframes: Keyframes?
        init?(_ item: Item) {
            switch item {
            case .video(let c): id = c.id; volume = c.volume; muted = c.muted; fadeInSec = c.fadeInSec; fadeOutSec = c.fadeOutSec; keyframes = c.keyframes
            case .audio(let c): id = c.id; volume = c.volume; muted = c.muted; fadeInSec = c.fadeInSec; fadeOutSec = c.fadeOutSec; keyframes = c.keyframes
            default: return nil
            }
        }
    }

    /// Base gain of a clip at timeline t, without ducking (volume, keyframes, fades, transition crossfade).
    private static func baseGain(_ p: Project, _ track: Track, _ item: Item, _ s: Sound, _ spans: [MainSpan], _ t: Double) -> Double {
        if p.mute == true || track.muted == true || s.muted == true { return 0 }
        if case .video(let v) = item, v.holdSec != nil { return 0 }   // wave 1: a freeze frame is silent
        let span = itemSpan(p, track, item)
        if t < span.startSec - 1e-9 || t > span.endSec + 1e-9 { return 0 }
        let local = t - span.startSec, len = span.endSec - span.startSec
        var g = (track.volume ?? 1) * propAt(s.keyframes, .volume, fallback: s.volume ?? 1, local)
        if let f = s.fadeInSec, f > 0 { g *= clamp(local / f, 0, 1) }
        if let f = s.fadeOutSec, f > 0 { g *= clamp((len - local) / f, 0, 1) }
        if track.kind == .main, let i = spans.firstIndex(where: { $0.id == s.id }) {
            let me = spans[i]
            if me.transitionSec > 0 { g *= clamp(local / me.transitionSec, 0, 1) }
            if i + 1 < spans.count, spans[i + 1].transitionSec > 0 { g *= clamp((me.endSec - t) / spans[i + 1].transitionSec, 0, 1) }
        }
        return g
    }

    /// Ducking multiplier at t for a music track with `duck`.
    private static func duckGain(_ regions: [SecRange], _ duck: Duck, _ t: Double) -> Double {
        let level = clamp(duck.level ?? 0.3, 0.05, 1), (att, rel) = duckTimes(duck)
        var m = 1.0
        for r in regions {
            let d: Double
            if t >= r.startSec && t <= r.endSec { d = 1 }
            else if t < r.startSec { d = clamp(1 - (r.startSec - t) / att, 0, 1) }
            else { d = clamp(1 - (t - r.endSec) / rel, 0, 1) }
            m = min(m, 1 - (1 - level) * d)
        }
        return m
    }

    /// A clip's gain over the timeline as piecewise-linear points (t ascending, timeline seconds, from the clip's start to its
    /// end). Points sit at every corner (fades, transitions, keyframes, duck ramps), so linear interpolation between them is
    /// exact except inside eased keyframes, which are sampled every 0.1 s. Empty for items without sound.
    public static func audioEnvelope(_ p: Project, trackId: String, itemId: String) -> [GainPoint] {
        guard let track = p.track(trackId), let item = track.item(itemId), let s = Sound(item) else { return [] }
        let span = itemSpan(p, track, item)
        let end = min(span.endSec, durationSec(p))
        if end <= span.startSec { return [] }
        let spans = timeline(p)
        var ts: Set<Double> = [span.startSec, end]
        func add(_ t: Double) { if t > span.startSec && t < end { ts.insert(r6(t)) } }
        if let f = s.fadeInSec, f != 0, !f.isNaN { add(span.startSec + f) }
        if let f = s.fadeOutSec, f != 0, !f.isNaN { add(span.endSec - f) }
        if track.kind == .main, let i = spans.firstIndex(where: { $0.id == s.id }) {
            let me = spans[i]
            if me.transitionSec != 0 { add(me.startSec + me.transitionSec) }
            if i + 1 < spans.count, spans[i + 1].transitionSec != 0 { add(spans[i + 1].startSec) }
        }
        let kv = s.keyframes?.volume ?? []
        for (idx, k) in kv.enumerated() {
            add(span.startSec + k.t)
            if idx + 1 < kv.count, let e = k.ease, e != .linear {
                let nk = kv[idx + 1]
                if e == .hold { add(span.startSec + nk.t - 1e-4) }
                else {
                    var x = k.t + 0.1
                    while x < nk.t - 1e-9 { add(span.startSec + x); x += 0.1 }
                }
            }
        }
        var regions: [SecRange] = []
        var duck: Duck?
        if track.kind == .music, let d = track.duck {
            duck = d
            regions = duckRegions(p, d)
            let (att, rel) = duckTimes(d)
            for r in regions { add(r.startSec - att); add(r.startSec); add(r.endSec); add(r.endSec + rel) }

        }
        return ts.sorted().map { t in
            var g = baseGain(p, track, item, s, spans, t)
            if let duck, !regions.isEmpty { g *= duckGain(regions, duck, t) }
            return GainPoint(t: r6(t), gain: r6(g))
        }
    }

    /// The gain of an envelope at timeline t (linear between points, 0 outside).
    public static func gain(_ env: [GainPoint], at t: Double) -> Double {
        guard let first = env.first, let last = env.last, t >= first.t, t <= last.t else { return 0 }
        for i in 0..<(env.count - 1) where t <= env[i + 1].t {
            let a = env[i], b = env[i + 1]
            return b.t > a.t ? a.gain + (b.gain - a.gain) * (t - a.t) / (b.t - a.t) : b.gain
        }
        return last.gain
    }
}
