import Foundation

// Overlay cross-dissolves, split voice and music, and cut out a picture (WS8 3d62419 / b5cb9248; model.ts overlayFade,
// applySeparation, applyCutout with the functions.json overlayFades / separation / cutout fixtures).

extension EditV2 {
    /// Cross-dissolve between overlays: the alpha multiplier of `item` on overlay `track` at timeline `t` (after keyframes
    /// and animation, before blend). An item with a fade transitionIn rises over its first durationSec; the item before
    /// it falls over the same overlap. 1 elsewhere.
    public static func overlayFade(_ p: Project, _ track: Track, _ item: Item, _ t: Double) -> Double {
        guard track.kind == .video || track.kind == .image, let i = track.items.firstIndex(where: { $0.id == item.id }) else { return 1 }
        func fadeIn(_ it: Item) -> Transition? {
            switch it {
            case .video(let c): return c.transitionIn
            case .image(let im): return im.transitionIn
            default: return nil
            }
        }
        let me = itemSpan(p, track, item)
        var a = 1.0
        if let tin = fadeIn(item), i > 0, t < me.startSec + tin.durationSec { a *= clamp((t - me.startSec) / tin.durationSec, 0, 1) }
        if i + 1 < track.items.count, let tn = fadeIn(track.items[i + 1]) {
            let ns = itemSpan(p, track, track.items[i + 1]).startSec
            if t >= ns { a *= clamp(1 - (t - ns) / tn.durationSec, 0, 1) }
        }
        return r6(a)
    }

    public enum SeparationKeep: String, Codable, Hashable, Sendable { case vocals, instrumental, both }

    /// Split voice and music (the `separate` helper): clip `clipId` (main or overlay video) is muted and the kept part(s)
    /// go on audio tracks in sync with it: vocals on a voice track, instrumental on a music track (the first of that kind
    /// free over the clip's span, else a new one), each with the clip's inSec/outSec and speed, starting where the clip
    /// starts. The assets must already be in the project. Nil for a freeze frame, a speed curve, a speed outside 0.5–2,
    /// or when a new track would pass the track limit.
    public static func applySeparation(_ p: Project, clipId: String, vocals: String, instrumental: String, keep: SeparationKeep) -> (project: Project, ids: [String])? {
        guard let ti = p.tracks.firstIndex(where: { ($0.kind == .main || $0.kind == .video) && $0.items.contains { $0.id == clipId } }),
              let ii = p.tracks[ti].items.firstIndex(where: { $0.id == clipId }), case .video(var c) = p.tracks[ti].items[ii] else { return nil }
        let speed = c.speed ?? 1
        guard c.holdSec == nil, c.speedCurve == nil, speed >= 0.5 - 1e-9, speed <= 2 + 1e-9 else { return nil }
        let span = itemSpan(p, p.tracks[ti], p.tracks[ti].items[ii])
        var q = p
        c.muted = true
        q.tracks[ti].items[ii] = .video(c)
        var taken = Set(p.tracks.flatMap { [$0.id] + $0.items.map(\.id) })
        func fresh(_ base: String) -> String {
            var n = 1
            while taken.contains("\(base)\(n)") { n += 1 }
            taken.insert("\(base)\(n)")
            return "\(base)\(n)"
        }
        var parts: [(TrackKind, String)] = []
        if keep != .instrumental { parts.append((.voice, vocals)) }
        if keep != .vocals { parts.append((.music, instrumental)) }
        var ids: [String] = []
        for (kind, asset) in parts {
            let clip = AudioClip(id: fresh(kind == .voice ? "vocals" : "instr"), asset: asset, startSec: r6(span.startSec), inSec: c.inSec, outSec: c.outSec,
                                 speed: speed != 1 ? c.speed : nil)
            let free = { (t: Track) -> Bool in
                t.items.allSatisfy { i in
                    let sp = itemSpan(q, t, i)
                    return sp.endSec <= span.startSec + overlapSlackSec || sp.startSec >= span.endSec - overlapSlackSec
                }
            }
            if let at = q.tracks.firstIndex(where: { $0.kind == kind && free($0) }) {
                q.tracks[at].items.append(.audio(clip))
                q.tracks[at].items.sort { $0.startSec < $1.startSec }
            } else {
                guard q.tracks.count < maxTracks else { return nil }
                q.tracks.append(Track(id: fresh(kind.rawValue), kind: kind, items: [.audio(clip)]))
            }
            ids.append(clip.id)
        }
        return (q, ids)
    }

    /// The box of a cut-out in its source picture's pixels.
    public struct CutoutBox: Codable, Hashable, Sendable {
        public var x: Double, y: Double, w: Double, h: Double
        public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    }

    /// Cut out a picture (the `cutout` helper): image item `itemId` switches to the cut-out `assetId` and stays exactly
    /// where the subject sat: scale and x/y move so the cut-out covers the box's place; the crop is dropped; mask, look,
    /// blend and animations stay. Scale keys are multiplied by the same ratio and x/y keys get the same offset. Nil if it
    /// isn't an image item.
    public static func applyCutout(_ p: Project, itemId: String, assetId: String, box: CutoutBox, sourceWidth sw: Double, sourceHeight sh: Double) -> Project? {
        guard let ti = p.tracks.firstIndex(where: { $0.kind == .image && $0.items.contains { $0.id == itemId } }),
              let ii = p.tracks[ti].items.firstIndex(where: { $0.id == itemId }), case .image(var im) = p.tracks[ti].items[ii],
              sw > 0, sh > 0, box.w > 0, box.h > 0 else { return nil }
        let cw = Double(p.canvas.width), ch = Double(p.canvas.height), cv = cw / ch
        let fw = { (w: Double, h: Double) in im.fit == .cover ? max(1, (w / h) / cv) : min(1, (w / h) / cv) }
        let tr = im.transform ?? Transform()
        let scale = tr.scale ?? 1, rot = (tr.rotation ?? 0) * .pi / 180
        let k = fw(sw, sh) * scale / sw
        let scale2 = box.w * k / fw(box.w, box.h)
        var dx = (box.x + box.w / 2 - sw / 2) * k, dy = (box.y + box.h / 2 - sh / 2) * k * cv
        if tr.flipX == true { dx = -dx }
        if tr.flipY == true { dy = -dy }
        let px = dx * cw, py = dy * ch
        let ox = (px * cos(rot) - py * sin(rot)) / cw, oy = (px * sin(rot) + py * cos(rot)) / ch
        let ratio = scale2 / scale
        if var keys = im.keyframes {
            for (prop, ks) in keys.present {
                switch prop {
                case .scale: keys[prop] = ks.map { var k = $0; k.v = r6(k.v * ratio); return k }
                case .x: keys[prop] = ks.map { var k = $0; k.v = r6(k.v + ox); return k }
                case .y: keys[prop] = ks.map { var k = $0; k.v = r6(k.v + oy); return k }
                default: break
                }
            }
            im.keyframes = keys
        }
        im.crop = nil
        im.asset = assetId
        var t2 = tr
        t2.x = r6((tr.x ?? 0.5) + ox); t2.y = r6((tr.y ?? 0.5) + oy); t2.scale = r6(scale2)
        im.transform = t2
        var q = p
        q.tracks[ti].items[ii] = .image(im)
        return q
    }
}
