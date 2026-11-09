import Foundation

// Parity (plans/edit-parity.md, M rows; Swift port of WS8 c8875ec): keyframes on the timeline (drag a ◆ to move every
// property's key at that time), a curves editor on look.curves, and auto adjust from the frame under the playhead.

extension EditV2 {
    /// Auto adjust: one frame's levels (`rgb` = r, g, b, … straight sRGB 0–1) → a gentle Adjust for the colour matrix
    /// (exposure → temperature → tint → contrast → saturation). Highlights and shadows of `base` are kept. Same numbers as
    /// Android's core `autoAdjust`.
    public static func autoAdjust(_ rgb: [Double], base: Adjust? = nil) -> Adjust {
        let n = rgb.count / 3
        guard n > 0 else { return base ?? Adjust() }
        var r = 0.0, g = 0.0, b = 0.0, chroma = 0.0
        var luma = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let R = rgb[i * 3], G = rgb[i * 3 + 1], B = rgb[i * 3 + 2]
            r += R; g += G; b += B
            luma[i] = 0.2126 * R + 0.7152 * G + 0.0722 * B
            chroma += max(R, G, B) - min(R, G, B)
        }
        let dn = Double(n)
        r /= dn; g /= dn; b /= dn; chroma /= dn
        luma.sort()
        let mean = luma.reduce(0, +) / dn
        let lo = luma[min(n - 1, max(0, Int(dn * 0.02)))], hi = luma[min(n - 1, max(0, Int(dn * 0.98)))]
        func cl(_ v: Double, _ a: Double, _ z: Double) -> Double { min(z, max(a, v)) }
        // Exposure: the mean towards 0.45 (2^e), at most ±0.6 stop.
        let e = mean > 1e-3 ? cl(log2(0.45 / mean), -0.6, 0.6) : 0.6
        // Contrast: the 2–98 % spread towards 0.85.
        let spread = hi - lo
        let c = spread > 1e-3 ? cl(0.85 / spread - 1, -0.3, 0.4) : 0
        // White balance, half-way: red and blue level (temperature), then green against magenta (tint).
        let rb = (r + b) / 2
        let t = r + b > 1e-3 ? cl((b - r) / (0.1 * (r + b)) * 0.5, -1, 1) : 0
        let tn = g > 1e-3 ? cl((g - rb) / (0.1 * g + 0.05 * rb) * 0.5, -1, 1) : 0
        // Saturation: lift flat footage a little, calm very saturated footage.
        let s = chroma < 0.08 ? 0.15 : chroma > 0.35 ? -0.1 : 0
        func nz(_ v: Double) -> Double? { let x = jsRound(v * 100) / 100; return x == 0 ? nil : x }
        var a = base ?? Adjust()
        a.exposure = nz(e); a.contrast = nz(c); a.saturation = nz(s); a.temperature = nz(t); a.tint = nz(tn)
        return a
    }
}

extension EditSuite {
    /// A tone curve channel of `look.curves`.
    public enum CurveChannel: String, CaseIterable, Sendable, Identifiable {
        case rgb, r, g, b
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .rgb: return "All"
            case .r: return "Red"
            case .g: return "Green"
            case .b: return "Blue"
            }
        }
    }
}

extension EditSuiteState {
    // MARK: Keyframes on the timeline

    static func keyframes(of it: E.Item) -> E.Keyframes? {
        switch it {
        case .video(let c): return c.keyframes
        case .image(let c): return c.keyframes
        case .text(let c): return c.keyframes
        case .audio(let c): return c.keyframes
        case .adjust(let c): return c.keyframes
        }
    }

    static func setKeyframes(_ it: inout E.Item, _ k: E.Keyframes?) {
        switch it {
        case .video(var c): c.keyframes = k; it = .video(c)
        case .image(var c): c.keyframes = k; it = .image(c)
        case .text(var c): c.keyframes = k; it = .text(c)
        case .audio(var c): c.keyframes = k; it = .audio(c)
        case .adjust(var c): c.keyframes = k; it = .adjust(c)
        }
    }

    /// An item's keyframe times (item seconds, every property, sorted; keys within 0.05 s count as one).
    public func keyTimes(_ itemId: String) -> [Double] {
        guard let loc = project.locate(itemId), let k = Self.keyframes(of: project.tracks[loc.track].items[loc.item]) else { return [] }
        var out: [Double] = []
        for t in k.present.flatMap({ $0.1.map(\.t) }).sorted() where out.last.map({ t - $0 > 0.05 }) ?? true { out.append(t) }
        return out
    }

    /// The project with the keys at item time `fromT` (±0.05 s, every property) moved by `delta`, kept inside the item and in
    /// order; nil when that would land on or pass another key of the same property. Measured from where a gesture started.
    public func movingKeys(_ itemId: String, from fromT: Double, by delta: Double) -> E.Project? {
        let p = gestureBase ?? project
        guard !isLocked(itemId), let loc = p.locate(itemId) else { return nil }
        let track = p.tracks[loc.track]
        let item = track.items[loc.item]
        guard var k = Self.keyframes(of: item) else { return nil }
        let sp = E.itemSpan(p, track, item)
        let to = E.jsRound(min(max(0, fromT + delta), sp.endSec - sp.startSec) * 1000) / 1000
        guard abs(to - fromT) > 1e-9 else { return nil }
        var moved = false
        for (prop, list) in k.present {
            let others = list.filter { abs($0.t - fromT) > 0.05 }
            guard others.count != list.count else { continue }
            if others.contains(where: { ($0.t - fromT) * ($0.t - to) <= 0 || abs($0.t - to) <= 0.05 }) { return nil }
            k[prop] = list.map { kf in
                guard abs(kf.t - fromT) <= 0.05 else { return kf }
                var m = kf; m.t = to; return m
            }.sorted { $0.t < $1.t }
            moved = true
        }
        guard moved else { return nil }
        return p.updating(itemId) { Self.setKeyframes(&$0, k) }
    }

    /// Moves the keys at item time `fromT` by `delta` as one undo step (outside a drag).
    @discardableResult
    public mutating func moveKeys(_ itemId: String, from fromT: Double, by delta: Double) -> Bool {
        guard let next = movingKeys(itemId, from: fromT, by: delta) else { return false }
        return apply { _ in next }
    }

    // MARK: Curves

    /// The selected picture's curve of `ch` ([x, y] points), or nil for the straight line.
    public func curve(_ ch: EditSuite.CurveChannel) -> E.CurvePoints? {
        guard let c = selectedVisual?.look?.curves else { return nil }
        switch ch {
        case .rgb: return c.rgb
        case .r: return c.r
        case .g: return c.g
        case .b: return c.b
        }
    }

    /// Sets a tone curve of the selected video or picture: points rounded to 0.001, clamped to 0–1 and sorted by x; nil or the
    /// straight line removes the channel (and the look when nothing else is left). Two points at the same x are refused.
    @discardableResult
    public mutating func setCurve(_ ch: EditSuite.CurveChannel, _ points: E.CurvePoints?) -> Bool {
        guard selectedVisual != nil, selectedItem?.textItem == nil else { return false }
        func r3(_ v: Double) -> Double { E.jsRound(min(1, max(0, v)) * 1000) / 1000 }
        var pts = points?.filter { $0.count == 2 }.map { [r3($0[0]), r3($0[1])] }.sorted { $0[0] < $1[0] }
        if let q = pts, q.count == 2, q[0] == [0, 0], q[1] == [1, 1] { pts = nil }
        if let q = pts, zip(q, q.dropFirst()).contains(where: { $0[0] == $1[0] }) {
            refuse("That curve can't be used · keep points apart"); return false
        }
        let ok = changeVisual { v in
            var l = v.look ?? E.Look()
            var c = l.curves ?? E.Curves()
            switch ch {
            case .rgb: c.rgb = pts
            case .r: c.r = pts
            case .g: c.g = pts
            case .b: c.b = pts
            }
            l.curves = (c.rgb == nil && c.r == nil && c.g == nil && c.b == nil) ? nil : c
            v.look = l == E.Look() ? nil : l
        }
        if !ok, lastRefusal != nil { refuse("That curve can't be used · keep points apart") }
        return ok
    }

    // MARK: Auto adjust

    /// Auto adjust of the selected video or picture from the frame's levels (`rgb` straight 0–1). False when nothing changes.
    @discardableResult
    public mutating func autoAdjust(_ rgb: [Double]) -> Bool {
        guard let v = selectedVisual, selectedItem?.textItem == nil else { return false }
        let a = E.autoAdjust(rgb, base: v.adjust)
        let next = a == E.Adjust() ? nil : a
        guard next != v.adjust else { return false }
        return changeVisual { $0.adjust = next }
    }

    // MARK: Key colour from the picture (design pass, owner-approved: the chroma eyedropper)

    /// Where a canvas point (pixels, top-left origin) falls on the selected video clip's own source frame, as 0–1 of its width
    /// and height (before crop), at the playhead: the inverse of its fit, flip, scale, rotation and position. Nil when the
    /// point is off the clip or nothing fitting is selected.
    public func sourcePoint(canvasX x: Double, canvasY y: Double, sourceWidth sw: Double, sourceHeight sh: Double) -> (u: Double, v: Double)? {
        guard let c = selectedVideo, sw > 0, sh > 0 else { return nil }
        let cr = c.crop
        let l = cr?.left ?? 0, r = cr?.right ?? 0, t = cr?.top ?? 0, b = cr?.bottom ?? 0
        let cw = sw * max(0.1, 1 - l - r), ch = sh * max(0.1, 1 - t - b)
        var tf = c.transform ?? E.Transform()
        tf.x = visualValue(.x); tf.y = visualValue(.y); tf.scale = visualValue(.scale); tf.rotation = visualValue(.rotation)
        let fit = c.fit ?? (selectedIsMain ? .cover : .contain)
        let k = E.itemCorners(canvasWidth: Double(project.canvas.width), canvasHeight: Double(project.canvas.height), w: cw, h: ch, fit: fit, transform: tf)
        guard k.count == 4 else { return nil }
        // p = TL + u·(TR − TL) + v·(BL − TL): solve the 2×2 system.
        let ax = k[1][0] - k[0][0], ay = k[1][1] - k[0][1], bx = k[3][0] - k[0][0], by = k[3][1] - k[0][1]
        let det = ax * by - ay * bx
        guard abs(det) > 1e-9 else { return nil }
        let px = x - k[0][0], py = y - k[0][1]
        let u = (px * by - py * bx) / det, v = (ax * py - ay * px) / det
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return (l + u * (1 - l - r), t + v * (1 - t - b))
    }

    /// Sets the selected clip's key colour (one undo step); false when it has no chroma key.
    @discardableResult
    public mutating func setKeyColour(_ hex: String) -> Bool {
        guard selectedVideo?.chroma != nil else { return false }
        return changeChroma { $0.color = hex.uppercased() }
    }

    // MARK: Loop animations (contract, WS8 57fe40c)

    /// The selected item's loop (overlay clips, pictures and text), or nil.
    public var selectedLoop: E.AnimLoop? {
        switch selectedItem {
        case .video(let c): return c.animLoop
        case .image(let c): return c.animLoop
        case .text(let c): return c.animLoop
        default: return nil
        }
    }

    /// Whether the selected item can loop (an overlay clip, a picture or text; not a main clip or a sound).
    public var canLoop: Bool {
        switch selectedItem {
        case .video: return !selectedIsMain
        case .image, .text: return true
        default: return false
        }
    }

    /// Sets the selected item's loop (nil removes it): period 0.2–5 s, amount 0–1 (left out at the default 0.5).
    @discardableResult
    public mutating func setLoop(_ loop: E.AnimLoop?) -> Bool {
        guard canLoop else { return false }
        var l = loop
        if var x = l {
            x.periodSec = E.r3(min(5, max(0.2, x.periodSec)))
            x.amount = x.amount.map { E.r3(min(1, max(0, $0))) }.flatMap { abs($0 - 0.5) < 1e-9 ? nil : $0 }
            l = x
        }
        return changeSelected { it in
            switch it {
            case .video(var c): c.animLoop = l; it = .video(c)
            case .image(var c): c.animLoop = l; it = .image(c)
            case .text(var c): c.animLoop = l; it = .text(c)
            case .audio, .adjust: break
            }
        }
    }

    // MARK: Audio speed (contract, WS8 dacb556)

    /// The selected music, voice or effect clip's speed (pitch kept), or nil when no sound is selected.
    public var selectedAudioSpeed: Double? {
        guard case .audio(let c)? = selectedItem else { return nil }
        return c.speed ?? 1
    }

    /// Sets the selected sound's speed, 0.5–2× (1 is left out); its length on the timeline follows.
    @discardableResult
    public mutating func setAudioSpeed(_ s: Double) -> Bool {
        guard case .audio? = selectedItem else { return false }
        let v = min(2, max(0.5, (s * 100).rounded() / 100))
        return changeSelected { it in
            guard case .audio(var c) = it else { return }
            c.speed = abs(v - 1) < 1e-9 ? nil : v
            it = .audio(c)
        }
    }

    // MARK: Adjustment layers (contract, WS8 3e20288)

    /// The selected adjustment layer item, or nil.
    public var selectedAdjust: E.AdjustItem? { selectedItem?.adjustItem }

    /// Adds an adjustment layer at the playhead (3 s, or to the end), on the first adjustment track it fits, else a new one;
    /// selected.
    @discardableResult
    public mutating func addAdjustLayer(durationSec: Double = 3) -> Bool {
        let at = E.r6(min(max(0, playhead), max(0, duration - E.minItemSec)))
        var newId: String?
        let ok = apply { p in
            let d = E.r6(min(durationSec, max(E.minItemSec, E.durationSec(p) - at)))
            let id = p.newId("adj")
            let item = E.AdjustItem(id: id, startSec: at, durationSec: d)
            for t in p.tracks where t.kind == .adjust {
                if let r = p.adding(.adjust(item), toTrack: t.id) { newId = id; return r }
            }
            guard let r = p.addingTrack(.adjust, name: "Adjustment") else { return nil }
            newId = id
            return r.project.adding(.adjust(item), toTrack: r.trackId)
        }
        if ok { selection = newId; tab = .video }
        return ok
    }

    /// The selected layer's filter preset (nil removes it), amount 0–1.
    @discardableResult
    public mutating func setLayerFilter(_ id: String?, amount: Double = 1) -> Bool {
        guard selectedAdjust != nil else { return false }
        let f = id.map { E.FilterRef(id: $0, amount: E.r3(min(1, max(0, amount)))) }
        return changeSelected { it in
            guard case .adjust(var c) = it else { return }
            c.filter = f
            it = .adjust(c)
        }
    }

    // MARK: Own fonts (contract, WS8 6ccd9aa)

    /// The project's own fonts (font assets), in the order they were added.
    public var ownFonts: [E.Asset] { project.assets.filter { $0.kind == .font } }

    /// Adds a checked font upload as a font asset (if new) and sets it on the selected text; nil `asset` puts the built-in
    /// family back.
    @discardableResult
    public mutating func setTextFont(_ asset: E.Asset?) -> Bool {
        guard selectedItem?.textItem != nil else { return false }
        if let a = asset, a.kind != .font { return false }
        let sel = selection
        return apply { p in
            var q = asset.map { p.addingAsset($0) } ?? p
            guard let id = sel, let r = q.updating(id, { it in
                guard case .text(var tx) = it else { return }
                tx.style.fontAsset = asset?.id
                it = .text(tx)
            }) else { return nil }
            q = r
            return q
        }
    }
}
