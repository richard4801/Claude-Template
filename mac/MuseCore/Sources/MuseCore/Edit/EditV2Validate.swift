import Foundation

// The server's rules for a v2 project (plans/video-editor.md "Rules"): a port of validate() in
// server/api/src/editor/model.ts with the same field paths, checked in the same order, so the first problem matches.
// Type errors the reference also catches (a string where a number goes, an unknown kind) already fail decoding here.

extension EditV2 {
    public struct EditProblem: Error, Hashable, Sendable, CustomStringConvertible {
        /// Field path like "edits.tracks.0.items.1.startSec".
        public var field: String
        public var message: String
        public init(_ field: String, _ message: String) { self.field = field; self.message = message }
        public var description: String { "\(field): \(message)" }
    }

    /// The first rule broken, or nil.
    /// `lookIds` = the bundled looks a "pack:<id>" may name (empty = any); `paletteIds` = the suite looks a
    /// "palette:<id>" may name (empty = none shipped, so any is refused).
    public static func problem(_ p: Project, presets: [FilterPreset] = filters, lookIds: Set<String> = Set(lookPackIds), paletteIds: Set<String> = []) -> EditProblem? {
        do { _ = try validate(p, presets: presets, lookIds: lookIds, paletteIds: paletteIds); return nil } catch let e as EditProblem { return e } catch { return EditProblem("edits", "\(error)") }
    }

    /// Checks every rule; throws the first EditProblem. Returns the project's duration.
    @discardableResult
    public static func validate(_ p: Project, presets: [FilterPreset] = filters, lookIds: Set<String> = Set(lookPackIds), paletteIds: Set<String> = []) throws -> Double {
        var v = Validator(p: p, filterIds: Set(presets.map(\.id)), lookIds: lookIds, paletteIds: paletteIds)
        return try v.run()
    }
}

private struct Validator {
    typealias E = EditV2
    let p: EditV2.Project
    let filterIds: Set<String>
    let lookIds: Set<String>
    let paletteIds: Set<String>
    var assets: [String: EditV2.Asset] = [:]
    var assetKinds: [String: EditV2.AssetKind] = [:]

    init(p: EditV2.Project, filterIds: Set<String>, lookIds: Set<String>, paletteIds: Set<String>) {
        self.p = p; self.filterIds = filterIds; self.lookIds = lookIds; self.paletteIds = paletteIds
    }

    func bad(_ f: String, _ m: String) -> EditV2.EditProblem { EditV2.EditProblem(f, m) }

    static func fmt(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e15 { return String(Int(v)) }
        return "\(v)"
    }

    func num(_ f: String, _ v: Double?, _ lo: Double, _ hi: Double, optional: Bool = true) throws {
        guard let v else {
            if optional { return }
            throw bad(f, "must be a number from \(Self.fmt(lo)) to \(Self.fmt(hi))")
        }
        if !v.isFinite || v < lo || v > hi { throw bad(f, "must be a number from \(Self.fmt(lo)) to \(Self.fmt(hi))") }
    }
    func num(_ f: String, _ v: Int?, _ lo: Double, _ hi: Double, optional: Bool = true) throws {
        try num(f, v.map(Double.init), lo, hi, optional: optional)
    }

    func color(_ f: String, _ v: String?, optional: Bool = true) throws {
        guard let v else {
            if optional { return }
            throw bad(f, "must be a colour like #FF0000")
        }
        let s = Array(v.utf8)
        let ok = s.count == 7 && s[0] == UInt8(ascii: "#") && s.dropFirst().allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        if !ok { throw bad(f, "must be a colour like #FF0000") }
    }

    func id(_ f: String, _ v: String) throws {
        let n = v.utf16.count
        if n < 1 || n > 64 { throw bad(f, "must be an id of 1–64 characters") }
    }

    mutating func run() throws -> Double {
        if p.version != 2 { throw bad("edits.version", "must be 2") }
        if p.sourceTakeId.isEmpty { throw bad("edits.sourceTakeId", "is required") }
        let cv = p.canvas
        try num("edits.canvas.width", cv.width, 16, 4096, optional: false)
        try num("edits.canvas.height", cv.height, 16, 4096, optional: false)
        try num("edits.canvas.fps", cv.fps, 1, 120, optional: false)
        try color("edits.canvas.background", cv.background)
        // Wave 1: canvas.fill is typed (color / blur): anything else fails decoding.
        if p.assets.count > E.maxAssets { throw bad("edits.assets", "must be a list of at most \(E.maxAssets)") }
        for (i, a) in p.assets.enumerated() {
            let f = "edits.assets.\(i)"
            try id("\(f).id", a.id)
            if assets[a.id] != nil { throw bad("\(f).id", "is used twice") }
            if a.kind == .lut && a.upload == nil { throw bad(f, "a lut asset must be an upload") }
            if a.kind == .font {
                if a.upload == nil { throw bad(f, "a font asset must be an upload") }
                if a.durationSec != nil { throw bad("\(f).durationSec", "is not part of a font asset") }
                if a.width != nil { throw bad("\(f).width", "is not part of a font asset") }
                if a.height != nil { throw bad("\(f).height", "is not part of a font asset") }
                if a.hasAudio != nil { throw bad("\(f).hasAudio", "is not part of a font asset") }
            }
            if let n = a.name, n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || n.utf16.count > 80 { throw bad("\(f).name", "must be 1–80 characters") }
            // The content library (WS8 929bcf2): `content:<pack>/<item>`, for stickers (image) and sound effects (audio).
            if let lib = a.library, lib.hasPrefix("content:"),
               lib.range(of: #"^content:[a-z0-9-]+/[a-z0-9_.-]+$"#, options: .regularExpression) == nil || (a.kind != .image && a.kind != .audio) {
                throw bad("\(f).library", "unknown content")
            }
            let refs = [a.take, a.upload, a.library].compactMap { $0 }
            if refs.count != 1 || refs.contains(where: { $0.isEmpty || $0.utf16.count > 100 }) { throw bad(f, "needs exactly one of take, upload or library") }
            try num("\(f).durationSec", a.durationSec, 0.01, 36_000)
            try num("\(f).width", a.width, 1, 16384)
            try num("\(f).height", a.height, 1, 16384)
            assets[a.id] = a
        }
        assetKinds = assets.mapValues(\.kind)
        // Helper copies (WS8 2df521a): a reversed copy (not of another reversed copy) or a derived copy (stabilize / slowmo)
        // of a video not made with the same step; at most one of the two, chains of up to 4, no cycles.
        for (i, a) in p.assets.enumerated() {
            let f = "edits.assets.\(i)"
            if a.reverseOf != nil && a.derivedFrom != nil { throw bad(f, "is either a reversed or a derived copy") }
            if let r = a.reverseOf {
                let o = assets[r]
                if a.kind != .video || o == nil || o!.kind != .video || o!.reverseOf != nil || o!.id == a.id {
                    throw bad("\(f).reverseOf", "must be a video asset")
                }
            }
            if let d = a.derivedFrom {
                guard let op = d.kind else { throw bad("\(f).derivedFrom.op", "must be stabilize or slowmo") }
                let o = assets[d.asset]
                if a.kind != .video || o == nil || o!.kind != .video || o!.id == a.id || o!.derivedFrom?.op == d.op {
                    throw bad("\(f).derivedFrom.asset", "must be a video asset")
                }
                if op == .stabilize {
                    if d.startSec != nil { throw bad("\(f).derivedFrom.startSec", "is not part of a steadied copy") }
                    if d.endSec != nil { throw bad("\(f).derivedFrom.endSec", "is not part of a steadied copy") }
                    if d.factor != nil { throw bad("\(f).derivedFrom.factor", "is not part of a steadied copy") }
                } else {
                    if !E.slowmoFactors.contains(d.factor ?? -1) { throw bad("\(f).derivedFrom.factor", "must be 2 or 4") }
                    try num("\(f).derivedFrom.startSec", d.startSec, 0, 36_000, optional: false)
                    try num("\(f).derivedFrom.endSec", d.endSec, 0, 36_000, optional: false)
                    let len = d.endSec! - d.startSec!
                    if len < E.slowmoMinRangeSec - 1e-9 || len > E.slowmoMaxRangeSec + 1e-9 {
                        throw bad("\(f).derivedFrom.endSec", "the range must be \(E.slowmoMinRangeSec)–\(Int(E.slowmoMaxRangeSec)) s")
                    }
                    if let od = o?.durationSec, d.endSec! > od + 0.01 { throw bad("\(f).derivedFrom.endSec", "is past the end of the video") }
                }
            }
            var id: String? = a.id
            var n = 0
            while let cur = id {
                if n > 4 { throw bad(f, "too many helper copies in a row") }
                let x = assets[cur]
                id = x?.derivedFrom?.asset ?? x?.reverseOf
                n += 1
            }
        }
        if p.tracks.isEmpty || p.tracks.count > E.maxTracks { throw bad("edits.tracks", "must have 1–\(E.maxTracks) tracks") }
        if p.tracks[0].kind != .main { throw bad("edits.tracks.0.kind", "the first track must be the main track") }
        if p.tracks.filter({ $0.kind == .main }).count != 1 { throw bad("edits.tracks", "needs exactly one main track") }
        if p.tracks.filter({ $0.kind == .caption }).count > 1 { throw bad("edits.tracks", "at most one caption track") }
        var ids = Set<String>()
        var total = 0

        for (ti, t) in p.tracks.enumerated() {
            let f = "edits.tracks.\(ti)"
            try id("\(f).id", t.id)
            if ids.contains(t.id) { throw bad("\(f).id", "is used twice") }
            ids.insert(t.id)
            try num("\(f).volume", t.volume, 0, 2)
            if t.items.count > E.maxItemsPerTrack { throw bad("\(f).items", "at most \(E.maxItemsPerTrack) items") }
            total += t.items.count
            if total > E.maxItems { throw bad("\(f).items", "at most \(E.maxItems) items in all") }
            if t.kind == .main && t.items.isEmpty { throw bad("\(f).items", "the main track needs at least one clip") }
            if t.kind == .caption {
                if !t.items.isEmpty { throw bad("\(f).items", "a caption track has no items") }
                guard let c = t.caption else { throw bad("\(f).caption", "is required") }
                if let a = assets[c.asset], a.kind == .video || a.kind == .audio {} else { throw bad("\(f).caption.asset", "must be a video or audio asset") }
                if c.words.count > E.maxWords { throw bad("\(f).caption.words", "at most \(E.maxWords) words") }
                func words(_ ws: [E.CaptionWord], _ g: String) throws {
                    for (j, w) in ws.enumerated() {
                        let n = w.text.utf16.count
                        if n < 1 || n > 60 { throw bad("\(g).\(j).text", "must be 1–60 characters") }
                        try num("\(g).\(j).startSec", w.startSec, 0, 36_000, optional: false)
                        try num("\(g).\(j).endSec", w.endSec, w.startSec, 36_000, optional: false)
                    }
                }
                try words(c.words, "\(f).caption.words")
                // Translated captions (WS8 cac2bb0).
                if let l = c.language, !E.isLanguageCode(l) { throw bad("\(f).caption.language", "must be a language code") }
                if let o = c.original {
                    if o.words.count > E.maxWords { throw bad("\(f).caption.original.words", "at most \(E.maxWords) words") }
                    try words(o.words, "\(f).caption.original.words")
                    if let l = o.language, !E.isLanguageCode(l) { throw bad("\(f).caption.original.language", "must be a language code") }
                }
                try textStyle("\(f).caption.style", c.style.textStyle, ownFont: false)
                try color("\(f).caption.style.highlightColor", c.style.highlightColor, optional: false)
                try num("\(f).caption.style.y", c.style.y, 0, 1)
                try num("\(f).caption.style.wordsPerPage", c.style.wordsPerPage, 1, 8)
                try num("\(f).caption.style.maxLines", c.style.maxLines, 1, 2)
            } else if t.caption != nil { throw bad("\(f).caption", "only on a caption track") }
            if let d = t.duck {
                if t.kind != .music { throw bad("\(f).duck", "only on a music track") }
                try num("\(f).duck.level", d.level, 0.05, 1)
                try num("\(f).duck.fadeSec", d.fadeSec, 0.05, 2)
                try num("\(f).duck.attackSec", d.attackSec, 0.05, 2)
                try num("\(f).duck.releaseSec", d.releaseSec, 0.05, 3)
                if d.under.isEmpty { throw bad("\(f).duck.under", "must list voice and/or speech") }
            }
            var prevEnd = -Double.infinity
            for (ii, it) in t.items.enumerated() {
                let g = "\(f).items.\(ii)"
                try id("\(g).id", it.id)
                if ids.contains(it.id) { throw bad("\(g).id", "is used twice") }
                ids.insert(it.id)
                switch (t.kind, it) {
                case (.main, .video(let c)), (.video, .video(let c)):
                    try clipBase(g, asset: c.asset, inSec: c.inSec, outSec: c.outSec, volume: c.volume, fadeIn: c.fadeInSec, fadeOut: c.fadeOutSec, kinds: [.video],
                                 voice: c.voiceEffect)
                    try num("\(g).speed", c.speed, E.minSpeed, E.maxSpeed, optional: false)
                    // Wave 1: a freeze frame plays at 1× without a speed curve; blend modes on overlay tracks only.
                    if let h = c.holdSec {
                        try num("\(g).holdSec", h, E.holdMinSec, E.holdMaxSec, optional: false)
                        if c.speed != 1 || c.speedCurve != nil { throw bad("\(g).holdSec", "a freeze frame plays at 1× without a speed curve") }
                    }
                    if c.blend != nil, t.kind != .video { throw bad("\(g).blend", "only on overlay tracks (video, image)") }
                    if let sc = c.speedCurve {
                        if !E.SpeedPreset.all.contains(sc.preset) { throw bad("\(g).speedCurve.preset", "unknown preset") }
                        if sc.points.count < 2 || sc.points.count > 16 { throw bad("\(g).speedCurve.points", "2–16 points") }
                        for (j, pt) in sc.points.enumerated() {
                            if pt.count != 2 || !pt[0].isFinite || !pt[1].isFinite || pt[0] < 0 || pt[0] > 1 || pt[1] < E.minSpeed || pt[1] > E.maxSpeed {
                                throw bad("\(g).speedCurve.points.\(j)", "must be [x 0–1, speed \(Self.fmt(E.minSpeed))–\(Self.fmt(E.maxSpeed))]")
                            }
                            if j > 0 && pt[0] <= sc.points[j - 1][0] { throw bad("\(g).speedCurve.points.\(j)", "x must increase") }
                        }
                        if sc.points[0][0] != 0 || sc.points[sc.points.count - 1][0] != 1 { throw bad("\(g).speedCurve.points", "must start at x 0 and end at x 1") }
                    }
                    let len = E.clipLength(c)
                    try visual(g, fit: c.fit, transform: c.transform, crop: c.crop, opacity: c.opacity, adjust: c.adjust, filter: c.filter, look: c.look, mask: c.mask)
                    try kfs("\(g).keyframes", c.keyframes, len, allowed: [.x, .y, .scale, .rotation, .opacity, .volume] + E.KfProp.color + E.KfProp.mask + E.KfProp.look, hasMask: c.mask != nil)
                    if let aa = c.audioAsset {
                        if let a = assets[aa], a.kind == .video || a.kind == .audio {} else { throw bad("\(g).audioAsset", "must be an audio or video asset") }
                    }
                    if let m = c.alphaMatte {
                        if let a = assets[m.asset], a.kind == .video {} else { throw bad("\(g).alphaMatte.asset", "must be a video asset") }
                    }
                    try anim("\(g).animIn", c.animIn, text: false)
                    try anim("\(g).animOut", c.animOut, text: false)
                    if c.animLoop != nil && t.kind == .main { throw bad("\(g).animLoop", "loop animations are for overlays, images and text") }
                    try loop("\(g).animLoop", c.animLoop)
                    if let ck = c.chroma {
                        try color("\(g).chroma.color", ck.color, optional: false)
                        try num("\(g).chroma.similarity", ck.similarity, 0, 1)
                        try num("\(g).chroma.smoothness", ck.smoothness, 0, 1)
                        try num("\(g).chroma.spill", ck.spill, 0, 1)
                    }
                    if t.kind == .main {
                        if c.startSec != nil { throw bad("\(g).startSec", "main clips play back to back (no startSec)") }
                        if let tr = c.transitionIn {
                            if ii == 0 { throw bad("\(g).transitionIn", "the first clip has no transition") }
                            try num("\(g).transitionIn.durationSec", tr.durationSec, E.minTransitionSec, E.maxTransitionSec, optional: false)
                            let prevLen = t.items[ii - 1].lengthSec
                            if tr.durationSec > len / 2 + 1e-9 || tr.durationSec > prevLen / 2 + 1e-9 {
                                throw bad("\(g).transitionIn.durationSec", "at most half of each clip")
                            }
                        }
                    } else {
                        if c.transitionIn != nil { throw bad("\(g).transitionIn", "transitions are on the main track only") }
                        try num("\(g).startSec", c.startSec, 0, 600, optional: false)
                    }
                case (.image, .image(let im)):
                    guard let a = assets[im.asset] else { throw bad("\(g).asset", "is not in assets") }
                    if a.kind != .image { throw bad("\(g).asset", "must be image") }
                    try num("\(g).startSec", im.startSec, 0, 600, optional: false)
                    try num("\(g).durationSec", im.durationSec, E.minItemSec, 600, optional: false)
                    try visual(g, fit: im.fit, transform: im.transform, crop: im.crop, opacity: im.opacity, adjust: im.adjust, filter: im.filter, look: im.look,
                               mask: im.mask)
                    try kfs("\(g).keyframes", im.keyframes, im.durationSec, allowed: [.x, .y, .scale, .rotation, .opacity] + E.KfProp.color + E.KfProp.mask + E.KfProp.look, hasMask: im.mask != nil)
                    try anim("\(g).animIn", im.animIn, text: false)
                    try anim("\(g).animOut", im.animOut, text: false)
                    try loop("\(g).animLoop", im.animLoop)
                case (.text, .text(let tx)):
                    let n = tx.text.utf16.count
                    if n < 1 || n > E.maxText { throw bad("\(g).text", "must be 1–\(E.maxText) characters") }
                    try num("\(g).startSec", tx.startSec, 0, 600, optional: false)
                    try num("\(g).durationSec", tx.durationSec, E.minItemSec, 600, optional: false)
                    try textStyle("\(g).style", tx.style, ownFont: true)
                    if tx.transform != nil { try visual(g, fit: nil, transform: tx.transform, crop: nil, opacity: nil, adjust: nil, filter: nil, look: nil) }
                    try num("\(g).opacity", tx.opacity, 0, 1)
                    try kfs("\(g).keyframes", tx.keyframes, tx.durationSec, allowed: [.x, .y, .scale, .rotation, .opacity])
                    try anim("\(g).animIn", tx.animIn, text: true)
                    try anim("\(g).animOut", tx.animOut, text: true)
                    try loop("\(g).animLoop", tx.animLoop)
                case (.music, .audio(let c)), (.voice, .audio(let c)), (.sfx, .audio(let c)):
                    try clipBase(g, asset: c.asset, inSec: c.inSec, outSec: c.outSec, volume: c.volume, fadeIn: c.fadeInSec, fadeOut: c.fadeOutSec, kinds: [.audio, .video],
                                 voice: c.voiceEffect)
                    try num("\(g).startSec", c.startSec, 0, 600, optional: false)
                    // Audio speed (contract, WS8 dacb556): 0.5–2×, pitch kept.
                    try num("\(g).speed", c.speed, 0.5, 2)
                    try kfs("\(g).keyframes", c.keyframes, E.clipLength(c), allowed: [.volume])
                    if let b = c.beats, b.count > 2000 || b.contains(where: { !$0.isFinite || $0 < 0 }) { throw bad("\(g).beats", "must be up to 2000 times") }
                    if let b = c.strongBeats, b.count > 2000 || b.contains(where: { !$0.isFinite || $0 < 0 }) { throw bad("\(g).strongBeats", "must be up to 2000 times") }
                case (.adjust, .adjust(let ad)):
                    // Adjustment layers (contract, WS8 3e20288): colour and strength only.
                    if let k = ad.strayKeys.first { throw bad("\(g).\(k)", "is not part of an adjustment layer") }
                    try num("\(g).startSec", ad.startSec, 0, 600, optional: false)
                    try num("\(g).durationSec", ad.durationSec, E.minItemSec, 600, optional: false)
                    if ad.adjust?.highlights != nil { throw bad("\(g).adjust.highlights", "is not part of an adjustment layer") }
                    if ad.adjust?.shadows != nil { throw bad("\(g).adjust.shadows", "is not part of an adjustment layer") }
                    try visual(g, fit: nil, transform: nil, crop: nil, opacity: ad.opacity, adjust: ad.adjust, filter: ad.filter, look: nil)
                    try kfs("\(g).keyframes", ad.keyframes, ad.durationSec, allowed: [.opacity] + E.KfProp.color)
                default:
                    break
                }
                if t.kind != .main {
                    if it.startSec < prevEnd - E.overlapSlackSec { throw bad("\(g).startSec", "items on a track must be in order and not overlap") }
                    prevEnd = E.itemSpan(p, t, it).endSec
                }
            }
        }
        let d = E.durationSec(p)
        if d < E.minOutputSec - 1e-9 { throw bad("edits", "the edited video must be at least \(Self.fmt(E.minOutputSec)) s") }
        if d > E.maxOutputSec + 1e-9 { throw bad("edits", "the edited video must be at most \(Self.fmt(E.maxOutputSec)) s") }
        return d
    }

    func clipBase(_ f: String, asset: String, inSec: Double, outSec: Double, volume: Double?, fadeIn: Double?, fadeOut: Double?, kinds: [EditV2.AssetKind],
                  voice: EditV2.VoiceEffect? = nil) throws {
        guard let a = assets[asset] else { throw bad("\(f).asset", "is not in assets") }
        if !kinds.contains(a.kind) { throw bad("\(f).asset", "must be " + kinds.map(\.rawValue).joined(separator: " or ")) }
        try num("\(f).inSec", inSec, 0, 36_000, optional: false)
        try num("\(f).outSec", outSec, 0, 36_000, optional: false)
        if outSec - inSec < E.minClipSourceSec - 1e-9 { throw bad("\(f).outSec", "a clip must keep at least \(Self.fmt(E.minClipSourceSec)) s of its source") }
        if let d = a.durationSec, outSec > d + E.endSlackSec { throw bad("\(f).outSec", "is past the end of its source") }
        try num("\(f).volume", volume, 0, 2)
        try num("\(f).fadeInSec", fadeIn, 0, 10)
        try num("\(f).fadeOutSec", fadeOut, 0, 10)
        if let v = voice, !EditV2.VoiceEffect.all.contains(v) { throw bad("\(f).voiceEffect", "one of " + EditV2.VoiceEffect.all.map(\.rawValue).joined(separator: ", ")) }
    }

    func visual(_ f: String, fit: EditV2.Fit?, transform: EditV2.Transform?, crop: EditV2.Crop?, opacity: Double?, adjust: EditV2.Adjust?, filter: EditV2.FilterRef?,
                look: EditV2.Look?, mask: EditV2.Mask? = nil) throws {
        if let t = transform {
            try num("\(f).transform.x", t.x, -2, 3)
            try num("\(f).transform.y", t.y, -2, 3)
            try num("\(f).transform.scale", t.scale, 0.05, 10)
            try num("\(f).transform.rotation", t.rotation, -3600, 3600)
        }
        if let c = crop {
            try num("\(f).crop.left", c.left, 0, 0.45)
            try num("\(f).crop.top", c.top, 0, 0.45)
            try num("\(f).crop.right", c.right, 0, 0.45)
            try num("\(f).crop.bottom", c.bottom, 0, 0.45)
        }
        try num("\(f).opacity", opacity, 0, 1)
        if let a = adjust {
            try num("\(f).adjust.exposure", a.exposure, -1, 1)
            try num("\(f).adjust.contrast", a.contrast, -1, 1)
            try num("\(f).adjust.saturation", a.saturation, -1, 1)
            try num("\(f).adjust.temperature", a.temperature, -1, 1)
            try num("\(f).adjust.tint", a.tint, -1, 1)
            try num("\(f).adjust.highlights", a.highlights, -1, 1)
            try num("\(f).adjust.shadows", a.shadows, -1, 1)
        }
        if let m = mask {
            if !EditV2.MaskShape.all.contains(m.shape) { throw bad("\(f).mask.shape", "one of " + EditV2.MaskShape.all.map(\.rawValue).joined(separator: ", ")) }
            try num("\(f).mask.x", m.x, -1, 2)
            try num("\(f).mask.y", m.y, -1, 2)
            try num("\(f).mask.width", m.width, 0.01, 3)
            try num("\(f).mask.height", m.height, 0.01, 3)
            try num("\(f).mask.rotation", m.rotation, -360, 360)
            try num("\(f).mask.feather", m.feather, 0, 1)
        }

        if let fl = filter {
            if !filterIds.isEmpty && !filterIds.contains(fl.id) { throw bad("\(f).filter.id", "unknown filter") }
            try num("\(f).filter.amount", fl.amount, 0, 1, optional: false)
        }
        if let lp = EditV2.lookProblem(look, assetKinds: assetKinds, packIds: lookIds, paletteIds: paletteIds) {
            throw bad(lp.field.isEmpty ? "\(f).look" : "\(f).look.\(lp.field)", lp.message)
        }
    }

    func kfs(_ f: String, _ k: EditV2.Keyframes?, _ len: Double, allowed: [EditV2.KfProp], hasMask: Bool = false) throws {
        guard let k else { return }
        for (prop, list) in k.present {
            if !allowed.contains(prop) { throw bad("\(f).\(prop.rawValue)", "is not a keyframe property here") }
            if prop.isMask && !hasMask { throw bad("\(f).\(prop.rawValue)", "needs a mask") }
            if list.count > E.maxKeyframes { throw bad("\(f).\(prop.rawValue)", "at most \(E.maxKeyframes) keyframes") }
            var prev = -Double.infinity
            let range: (Double, Double)
            switch prop {
            case .x, .y: range = (-2, 3)
            case .scale: range = (0.05, 10)
            case .rotation: range = (-3600, 3600)
            case .opacity: range = (0, 1)
            case .volume: range = (0, 2)
            case .exposure, .contrast, .saturation, .temperature, .tint, .vignette: range = (-1, 1)
            case .maskX, .maskY: range = (-1, 2)
            case .maskWidth, .maskHeight: range = (0.01, 3)
            case .maskRotation: range = (-360, 360)
            case .maskFeather, .grain, .leak: range = (0, 1)
            }
            for (j, kf) in list.enumerated() {
                let g = "\(f).\(prop.rawValue).\(j)"
                try num("\(g).t", kf.t, 0, len + E.endSlackSec, optional: false)
                if kf.t < prev { throw bad("\(g).t", "keyframes must be in time order") }
                prev = kf.t
                try num("\(g).v", kf.v, range.0, range.1, optional: false)
            }
        }
    }

    func loop(_ f: String, _ l: EditV2.AnimLoop?) throws {
        guard let l else { return }
        if !EditV2.LoopKind.all.contains(l.kind) { throw bad("\(f).kind", "unknown loop animation") }
        try num("\(f).periodSec", l.periodSec, 0.2, 5, optional: false)
        if let a = l.amount { try num("\(f).amount", a, 0, 1, optional: false) }
    }

    func anim(_ f: String, _ a: EditV2.Anim?, text: Bool) throws {
        guard let a else { return }
        if a.kind == .typewriter && !text { throw bad("\(f).kind", "unknown animation") }
        try num("\(f).durationSec", a.durationSec, 0.1, 2, optional: false)
    }

    func textStyle(_ f: String, _ s: EditV2.TextStyle, ownFont: Bool) throws {
        if let fa = s.fontAsset {
            if !ownFont { throw bad("\(f).fontAsset", "captions use the built-in fonts") }
            if assets[fa]?.kind != .font { throw bad("\(f).fontAsset", "must be a font asset") }
        }
        if ![400, 700, 900].contains(s.weight) { throw bad("\(f).weight", "must be 400, 700 or 900") }
        try num("\(f).sizePct", s.sizePct, 0.015, 0.25, optional: false)
        try color("\(f).color", s.color, optional: false)
        try num("\(f).maxWidthPct", s.maxWidthPct, 0.1, 1)
        try num("\(f).lineHeight", s.lineHeight, 0.8, 2)
        try num("\(f).letterSpacing", s.letterSpacing, -0.1, 0.5)
        if let st = s.stroke {
            try color("\(f).stroke.color", st.color, optional: false)
            try num("\(f).stroke.widthPct", st.widthPct, 0, 0.3, optional: false)
        }
        if let sh = s.shadow {
            try color("\(f).shadow.color", sh.color, optional: false)
            try num("\(f).shadow.opacity", sh.opacity, 0, 1, optional: false)
            try num("\(f).shadow.blurPct", sh.blurPct, 0, 1, optional: false)
            try num("\(f).shadow.dyPct", sh.dyPct, -1, 1, optional: false)
        }
        if let bg = s.background {
            try color("\(f).background.color", bg.color, optional: false)
            try num("\(f).background.opacity", bg.opacity, 0, 1, optional: false)
            try num("\(f).background.paddingPct", bg.paddingPct, 0, 1, optional: false)
            try num("\(f).background.radiusPct", bg.radiusPct, 0, 1, optional: false)
        }
    }
}
