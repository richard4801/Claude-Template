import Foundation

// Helper copies of a video (WS8 2df521a, model.ts deriveClip / applySlowmo / derivedOps / sourceOf / derivedLabel):
// a steadied copy (the same length and timing, so a clip switches with only its asset changing) and a smooth slow
// motion copy (a source range with frames interpolated, factor× as long and silent; the clip is split around it).

extension EditV2 {
    /// A clip switched to a steadied copy (op .stabilize) or back to its original (op nil): only the asset changes; the
    /// steadied frames move, so an alpha matte lined up with the original is dropped.
    public static func deriveClip(_ c: VideoClip, copy: String, op: DerivedOp?) -> VideoClip {
        var out = c
        out.asset = copy
        if op == .stabilize { out.alphaMatte = nil }
        return out
    }

    /// Keyframes of the item-local window [a, b]: the value at each edge plus the keys between, times from a × scale.
    static func sliceKeys(_ k: Keyframes?, _ a: Double, _ b: Double, _ scale: Double) -> Keyframes? {
        guard let k else { return nil }
        var out = Keyframes()
        for (prop, keys) in k.present where !keys.isEmpty {
            let ease = keys.last { $0.t <= a + 1e-9 }?.ease
            out[prop] = [Keyframe(t: 0, v: r6(keyframeValue(keys, a)), ease: ease)]
                + keys.filter { $0.t > a + 1e-9 && $0.t < b - 1e-9 }.map { var x = $0; x.t = r6((x.t - a) * scale); return x }
                + [Keyframe(t: r6((b - a) * scale), v: r6(keyframeValue(keys, b)))]
        }
        return out
    }

    /// Smooth slow motion: the main clip `clipId` split around the source range of the slowmo copy `slowId`; the middle
    /// piece plays the copy (in 0, out range × factor, speed 1, muted, no alpha matte or separate sound). Side pieces under
    /// 0.1 s of source are dropped; the first piece keeps the id, transition, fade and animation in, the last the fade and
    /// animation out; keyframes are sliced per piece (the middle's stretched); new ids are the next free `<id>.N`. Nil when
    /// it can't apply (a freeze frame, a speed curve, another asset, the range outside the clip).
    public static func applySlowmo(_ p: Project, clipId: String, slowId: String) -> (project: Project, id: String)? {
        guard let mi = p.tracks.firstIndex(where: { $0.kind == .main }) else { return nil }
        let items = p.tracks[mi].items
        guard let i = items.firstIndex(where: { $0.id == clipId }), case .video(let c) = items[i],
              let slow = p.asset(slowId), let d = slow.derivedFrom, d.kind == .slowmo, d.asset == c.asset, c.holdSec == nil, c.speedCurve == nil,
              let start = d.startSec, let end = d.endSec, let factor = d.factor else { return nil }
        if start < c.inSec - 1e-6 || end > c.outSec + 1e-6 || end - start < minClipSourceSec { return nil }
        let speed = c.speed ?? 1
        let midLen = r6(min((end - start) * factor, slow.durationSec ?? .infinity))
        let la = (start - c.inSec) / speed, lb = (end - c.inSec) / speed, len = clipLength(c)
        var ids = Set(p.tracks.flatMap { $0.items.map(\.id) })
        func nextId() -> String {
            var n = 2
            while ids.contains("\(c.id).\(n)") { n += 1 }
            let id = "\(c.id).\(n)"
            ids.insert(id)
            return id
        }
        var base = c
        base.transitionIn = nil; base.fadeInSec = nil; base.fadeOutSec = nil; base.animIn = nil; base.animOut = nil; base.keyframes = nil
        let keys = c.keyframes
        func withKeys(_ v: VideoClip, _ a: Double, _ b: Double, _ scale: Double) -> VideoClip {
            var v = v
            if let k = sliceKeys(keys, a, b, scale) { v.keyframes = k }
            return v
        }
        let hasBefore = start - c.inSec >= minClipSourceSec - 1e-9
        let hasAfter = c.outSec - end >= minClipSourceSec - 1e-9
        var pieces: [VideoClip] = []
        if hasBefore { var v = base; v.outSec = r6(start); pieces.append(withKeys(v, 0, la, 1)) }
        var plain = base
        plain.alphaMatte = nil; plain.audioAsset = nil
        let midId = hasBefore ? nextId() : c.id
        plain.id = midId; plain.asset = slowId; plain.inSec = 0; plain.outSec = midLen; plain.speed = 1; plain.muted = true
        pieces.append(withKeys(plain, la, lb, lb > la ? midLen / (lb - la) : 1))
        if hasAfter { var v = base; v.id = nextId(); v.inSec = r6(end); pieces.append(withKeys(v, lb, len, 1)) }
        if c.transitionIn != nil { pieces[0].transitionIn = c.transitionIn }
        if c.fadeInSec != nil { pieces[0].fadeInSec = c.fadeInSec }
        if c.animIn != nil { pieces[0].animIn = c.animIn }
        if c.fadeOutSec != nil { pieces[pieces.count - 1].fadeOutSec = c.fadeOutSec }
        if c.animOut != nil { pieces[pieces.count - 1].animOut = c.animOut }
        var q = p
        q.tracks[mi].items = Array(items[..<i]) + pieces.map { .video($0) } + Array(items[(i + 1)...])
        return (q, midId)
    }

    /// The helper steps from the original to `assetId`, in the order applied ("stabilize" | "slowmo" | "reverse").
    public static func derivedOps(_ p: Project, _ assetId: String) -> [String] {
        let byId = Dictionary(p.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ops: [String] = []
        var a = byId[assetId]
        var n = 0
        while let x = a, n < 8 {
            if let d = x.derivedFrom { ops.append(d.op); a = byId[d.asset] } else if let r = x.reverseOf { ops.append("reverse"); a = byId[r] } else { break }
            n += 1
        }
        return ops.reversed()
    }

    /// The original video an asset was made from (itself when it's not a copy).
    public static func sourceOf(_ p: Project, _ assetId: String) -> String {
        let byId = Dictionary(p.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var id = assetId
        for _ in 0..<8 {
            guard let next = byId[id]?.derivedFrom?.asset ?? byId[id]?.reverseOf, byId[next] != nil else { break }
            id = next
        }
        return id
    }

    /// The helper label in the order applied, e.g. "Steadied, reversed" or "Steadied, smooth 4×"; "" for an original.
    public static func derivedLabel(_ p: Project, _ assetId: String) -> String {
        let byId = Dictionary(p.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var words: [String] = []
        var a = byId[assetId]
        var n = 0
        while let x = a, n < 8 {
            if let d = x.derivedFrom {
                words.append(d.kind == .stabilize ? "steadied" : "smooth \(Int(d.factor ?? 0))×")
                a = byId[d.asset]
            } else if let r = x.reverseOf { words.append("reversed"); a = byId[r] } else { break }
            n += 1
        }
        let s = words.reversed().joined(separator: ", ")
        return s.isEmpty ? "" : s.prefix(1).uppercased() + s.dropFirst()
    }
}
