import Foundation

// Layers (plans/layers-edit.md, Phase 1; model.ts ClipLayer, LayerBase, TextPin and their functions): tracked objects of a
// main clip, each the clip's own picture drawn again over it through its matte, with its own colour; text behind a layer
// (aboveText) or pinned to one. Checked against the shared fixture layers.json.

extension EditV2 {
    /// One tracked object of its clip: the clip's picture again, cut out by `matte` (a grey video aligned with the clip's source,
    /// white = this object). look / filter replace the clip's, adjust is merged over it; recolor keeps the light and shade; blur
    /// and feather (0–1) per layerBlurPx / layerFeatherPx; aboveText draws it over text while the clip is steady.
    public struct ClipLayer: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var matte: String
        public var hidden: Bool?
        public var look: Look?
        public var adjust: Adjust?
        public var filter: FilterRef?
        public var recolor: Recolor?
        public var opacity: Double?
        public var blur: Double?
        public var feather: Double?
        public var aboveText: Bool?
        public var track: LayerTrack?
        public init(id: String, name: String, matte: String, track: LayerTrack? = nil) { self.id = id; self.name = name; self.matte = matte; self.track = track }
    }
    public struct Recolor: Codable, Hashable, Sendable {
        public var color: String
        public var amount: Double
        public init(color: String, amount: Double) { self.color = color; self.amount = amount }
    }
    /// Boxes [x, y, w, h] (0–1 of the source frame) every 1/fps s of the source from 0; nil = not seen.
    public struct LayerTrack: Codable, Hashable, Sendable {
        public var fps: Double
        public var boxes: [[Double]?]
        public init(fps: Double, boxes: [[Double]?]) { self.fps = fps; self.boxes = boxes }
    }
    /// The clip's own picture under its layers: hidden, blurred, its own colour, or another picture (`asset`) instead.
    public struct LayerBase: Codable, Hashable, Sendable {
        public var hidden: Bool?
        public var blur: Double?
        public var look: Look?
        public var adjust: Adjust?
        public var filter: FilterRef?
        public var asset: String?
        public init() {}
        public var isEmpty: Bool { hidden == nil && blur == nil && look == nil && adjust == nil && filter == nil && asset == nil }
    }
    public struct LayerSource: Codable, Hashable, Sendable {
        public var job: String
        public init(job: String) { self.job = job }
    }
    public enum PinAnchor: String, Codable, Hashable, Sendable, CaseIterable { case center, top, bottom }
    public struct PinOffset: Codable, Hashable, Sendable { public var x: Double; public var y: Double; public init(x: Double, y: Double) { self.x = x; self.y = y } }
    /// A text pinned to a layer: its centre on the layer's box (centre, top or bottom middle) plus offset (canvas 0–1).
    public struct TextPin: Codable, Hashable, Sendable {
        public var clip: String
        public var layer: String
        public var anchor: PinAnchor
        public var offset: PinOffset?
        public init(clip: String, layer: String, anchor: PinAnchor = .center, offset: PinOffset? = nil) { self.clip = clip; self.layer = layer; self.anchor = anchor; self.offset = offset }
    }

    public static let maxLayers = 5, maxLayerName = 40, maxTrackFps = 10.0, maxTrackSamples = 1250

    /// Reverse, stabilise and slow motion move the frames: the layers no longer line up and are dropped.
    public static func dropLayers(_ c: inout VideoClip) { c.layers = nil; c.layerBase = nil; c.layerSource = nil }

    /// The clip as drawn for one of its layers (model.ts layerClip).
    public static func layerClip(_ c: VideoClip, _ l: ClipLayer) -> VideoClip {
        var out = c
        out.layers = nil; out.layerBase = nil; out.layerSource = nil; out.chroma = nil; out.audioAsset = nil
        out.alphaMatte = AlphaMatte(asset: l.matte)
        out.muted = true
        out.look = l.look ?? c.look
        if let la = l.adjust { out.adjust = merged(c.adjust, la) }
        out.filter = l.filter ?? c.filter
        let k = l.opacity ?? 1
        let op = (c.opacity ?? 1) * k
        out.opacity = op != 1 ? r6(op) : nil
        if k != 1, var keys = c.keyframes, let o = keys[.opacity] {
            keys[.opacity] = o.map { var x = $0; x.v = r6(x.v * k); return x }
            out.keyframes = keys
        }
        return out
    }
    /// The clip as drawn under its layers (the Background row's colour over the clip's).
    public static func baseClip(_ c: VideoClip) -> VideoClip {
        guard let b = c.layerBase else { return c }
        var out = c
        if let l = b.look { out.look = l }
        if let a = b.adjust { out.adjust = merged(c.adjust, a) }
        if let f = b.filter { out.filter = f }
        return out
    }
    static func merged(_ a: Adjust?, _ b: Adjust) -> Adjust {
        var o = a ?? Adjust()
        if let v = b.exposure { o.exposure = v }; if let v = b.contrast { o.contrast = v }; if let v = b.saturation { o.saturation = v }
        if let v = b.temperature { o.temperature = v }; if let v = b.tint { o.tint = v }; if let v = b.highlights { o.highlights = v }; if let v = b.shadows { o.shadows = v }
        return o
    }

    /// Blur (layer or background) and feather (a layer's matte edge), 0–1, as a Gaussian sigma in canvas pixels.
    public static func layerBlurPx(width: Double, height: Double, _ v: Double?) -> Double { guard let v, v != 0 else { return 0 }; return r6(v * 0.02 * min(width, height)) }
    public static func layerFeatherPx(width: Double, height: Double, _ v: Double?) -> Double { guard let v, v != 0 else { return 0 }; return r6(v * 0.006 * min(width, height)) }

    static func rgbHsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2, d = mx - mn
        if d < 1e-9 { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        let h = mx == r ? ((g - b) / d + (g < b ? 6 : 0)) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
        return (h / 6, s, l)
    }
    static func hslRgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        if s < 1e-9 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func f(_ t0: Double) -> Double {
            let t = t0 < 0 ? t0 + 1 : t0 > 1 ? t0 - 1 : t0
            return t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p
        }
        return (f(h + 1.0 / 3), f(h), f(h - 1.0 / 3))
    }
    /// A layer's recolour of one pixel (0–1 RGB): the colour's hue and saturation, the pixel's light and shade moved to the
    /// colour's lightness (L' = Lc + (L − 0.5) × (1 − |2Lc − 1| / 2), clamped), mixed in by amount.
    public static func recolorPixel(_ rgb: (Double, Double, Double), _ rc: Recolor) -> (Double, Double, Double) {
        let c = hexRgb(rc.color)
        let (hc, sc, lc) = rgbHsl(c.0, c.1, c.2)
        let l = rgbHsl(rgb.0, rgb.1, rgb.2).2
        let o = hslRgb(hc, sc, clamp(lc + (l - 0.5) * (1 - abs(2 * lc - 1) / 2), 0, 1))
        let a = clamp(rc.amount, 0, 1)
        return (r6(rgb.0 + (o.0 - rgb.0) * a), r6(rgb.1 + (o.1 - rgb.1) * a), r6(rgb.2 + (o.2 - rgb.2) * a))
    }

    /// The layer's box at a source time: linear between the samples around it; a gap bridged up to 0.5 s; else nil.
    public static func layerBoxAt(_ track: LayerTrack?, _ sourceSec: Double) -> [Double]? {
        guard let tr = track, !tr.boxes.isEmpty, tr.fps > 0 else { return nil }
        let n = tr.boxes.count
        let f = max(0, sourceSec * tr.fps), reach = max(1, Int(jsRound(tr.fps / 2)))
        let i0 = min(n - 1, Int(f.rounded(.down)))
        var a = -1, b = -1
        var i = i0
        while i >= max(0, i0 - reach) { if tr.boxes[i] != nil { a = i; break }; i -= 1 }
        i = min(n - 1, i0 + (f > Double(i0) ? 1 : 0))
        while i <= min(n - 1, i0 + reach) { if tr.boxes[i] != nil { b = i; break }; i += 1 }
        if a < 0 && b < 0 { return nil }
        if a < 0 || b < 0 || a == b { return tr.boxes[a < 0 ? b : a]!.map(r6) }
        let u = clamp((f - Double(a)) / Double(b - a), 0, 1), A = tr.boxes[a]!, B = tr.boxes[b]!
        return (0..<4).map { r6(A[$0] + (B[$0] - A[$0]) * u) }
    }

    /// The timeline stretch where main clip `index` is on screen outside its transitions.
    public static func clipSteadyRange(_ p: Project, _ index: Int) -> SecRange? {
        let tl = timeline(p)
        guard tl.indices.contains(index) else { return nil }
        let s = tl[index]
        let end = index + 1 < tl.count ? tl[index + 1].startSec : s.endSec
        return SecRange(startSec: r6(s.startSec + s.transitionSec), endSec: r6(end))
    }

    public struct AboveTextLayer: Codable, Hashable, Sendable { public var clipId: String; public var layerId: String; public var local: Double }
    /// The layers drawn above the text at timeline t: aboveText (not hidden) layers of the main clip steadily on screen.
    public static func aboveTextLayersAt(_ p: Project, _ t: Double) -> [AboveTextLayer] {
        guard let main = p.mainTrack, main.hidden != true else { return [] }
        let tl = timeline(p), clips = p.mainClips
        for i in tl.indices {
            guard let r = clipSteadyRange(p, i) else { continue }
            if t < r.startSec - 1e-9 || t >= r.endSec - 1e-9 { continue }
            let c = clips[i]
            return (c.layers ?? []).filter { $0.aboveText == true && $0.hidden != true }.map { AboveTextLayer(clipId: c.id, layerId: $0.id, local: r6(t - tl[i].startSec)) }
        }
        return []
    }

    /// Where a pinned text's centre goes at timeline t (canvas 0–1), or nil (the text stays at its own x and y). `size` gives an
    /// asset's pixel size when the project doesn't carry it.
    public static func pinPoint(_ p: Project, _ pin: TextPin, _ t: Double, size: ((String) -> (Double, Double)?)? = nil) -> (x: Double, y: Double)? {
        let clips = p.mainClips, tl = timeline(p)
        guard let i = clips.firstIndex(where: { $0.id == pin.clip }), tl.indices.contains(i) else { return nil }
        let c = clips[i], span = tl[i]
        if t < span.startSec - 1e-9 || t >= span.endSec - 1e-9 { return nil }
        guard let l = c.layers?.first(where: { $0.id == pin.layer }) else { return nil }
        let wh = size?(c.asset) ?? p.assets.first { $0.id == c.asset }.flatMap { a in a.width.flatMap { w in a.height.map { (Double(w), Double($0)) } } }
        guard let (w, h) = wh, w > 0, h > 0 else { return nil }
        let local = t - span.startSec
        guard let box = layerBoxAt(l.track, clipSourceAt(c, local)) else { return nil }
        let u = box[0] + box[2] / 2, v = pin.anchor == .top ? box[1] : pin.anchor == .bottom ? box[1] + box[3] : box[1] + box[3] / 2
        let cl = c.crop?.left ?? 0, ct = c.crop?.top ?? 0, cw = 1 - cl - (c.crop?.right ?? 0), ch = 1 - ct - (c.crop?.bottom ?? 0)
        let uu = (u - cl) / cw, vv = (v - ct) / ch
        let tr = c.transform
        var at = Transform()
        at.x = propAt(c.keyframes, .x, fallback: tr?.x ?? 0.5, local); at.y = propAt(c.keyframes, .y, fallback: tr?.y ?? 0.5, local)
        at.scale = propAt(c.keyframes, .scale, fallback: tr?.scale ?? 1, local); at.rotation = propAt(c.keyframes, .rotation, fallback: tr?.rotation ?? 0, local)
        at.flipX = tr?.flipX; at.flipY = tr?.flipY
        let cv = p.canvas
        let k = itemCorners(canvasWidth: Double(cv.width), canvasHeight: Double(cv.height), w: w * cw, h: h * ch, fit: c.fit ?? .cover, transform: at)
        let TL = k[0], TR = k[1], BL = k[3]
        let px = TL[0] + uu * (TR[0] - TL[0]) + vv * (BL[0] - TL[0]), py = TL[1] + uu * (TR[1] - TL[1]) + vv * (BL[1] - TL[1])
        return (r6(px / Double(cv.width) + (pin.offset?.x ?? 0)), r6(py / Double(cv.height) + (pin.offset?.y ?? 0)))
    }
}
