import Foundation

// Mac Edit audit (2026-11-08, plans/mac-edit-audit.md): the inspector's controls that were broken or missing, as pure state
// operations so every one is unit-tested (EditSuiteControlsTests) and the app only wires them to views.

extension EditSuiteState {
    // MARK: Transform values at the playhead (keyframe aware)

    /// The selected item's playhead in its own time (seconds from its start on the timeline), or nil.
    public var selectedLocalTime: Double? {
        guard let s = selection, let loc = project.locate(s) else { return nil }
        let track = project.tracks[loc.track]
        let span = E.itemSpan(project, track, track.items[loc.item])
        return E.r6(min(max(0, playhead - span.startSec), span.endSec - span.startSec))
    }

    /// The static value of a transform property (what shows without keyframes).
    static func staticValue(_ v: EditSuite.Visual, _ prop: E.KfProp) -> Double {
        let tf = v.transform ?? E.Transform()
        switch prop {
        case .x: return tf.x ?? 0.5
        case .y: return tf.y ?? 0.5
        case .scale: return tf.scale ?? 1
        case .rotation: return tf.rotation ?? 0
        case .opacity: return v.opacity ?? 1
        case .volume: return 1
        case .exposure, .contrast, .saturation, .temperature, .tint: return v.adjust?[prop] ?? 0
        }
    }

    /// The value a transform property has at the playhead: its keyframes there when it has any, else the static value.
    public func visualValue(_ prop: E.KfProp) -> Double? {
        guard let v = selectedVisual else { return nil }
        if let keys = v.keyframes?[prop], !keys.isEmpty, let t = selectedLocalTime { return E.keyframeValue(keys, t) }
        return Self.staticValue(v, prop)
    }

    /// Sets a transform property of the selected item. A keyframed property gets a key at the playhead with the value (a
    /// keyframed property ignores its static value, so before this fix the slider moved and the picture didn't).
    @discardableResult
    public mutating func setVisualValue(_ prop: E.KfProp, _ value: Double) -> Bool {
        guard let v = selectedVisual, prop != .volume else { return false }
        if prop.isColor && selectedItem?.textItem != nil { return false }
        let value = prop.isColor ? E.r6(min(1, max(-1, value))) : value
        if let keys = v.keyframes?[prop], !keys.isEmpty { return addKeyframe(prop, value: value, ease: keys.first?.ease ?? .easeInOut) }
        if prop.isColor {
            return changeVisual { vv in
                var a = vv.adjust ?? E.Adjust()
                a[prop] = abs(value) < 0.005 ? nil : value
                vv.adjust = a == E.Adjust() ? nil : a
            }
        }
        return changeVisual { vv in
            var tf = vv.transform ?? E.Transform()
            switch prop {
            case .x: tf.x = E.r6(value)
            case .y: tf.y = E.r6(value)
            case .scale: tf.scale = E.r6(min(10, max(0.05, value)))
            case .rotation: tf.rotation = E.r6(min(3600, max(-3600, value)))
            case .opacity: vv.opacity = E.r6(min(1, max(0, value))); return
            case .volume, .exposure, .contrast, .saturation, .temperature, .tint: return
            }
            vv.transform = tf
        }
    }

    /// Whether the selected item has a key of `prop` at the playhead (within half a frame).
    public func hasKeyframe(_ prop: E.KfProp) -> Bool {
        guard let keys = selectedVisual?.keyframes?[prop], let t = selectedLocalTime else { return false }
        let tol = 0.5 / max(1, project.canvas.fps)
        return keys.contains { abs($0.t - t) <= tol }
    }

    /// Removes the key of `prop` at the playhead (the property goes back to its static value when it was the last one).
    @discardableResult
    public mutating func removeKeyframe(_ prop: E.KfProp) -> Bool {
        guard let t = selectedLocalTime else { return false }
        let tol = 0.5 / max(1, project.canvas.fps)
        return changeVisual { v in
            guard var k = v.keyframes, let list = k[prop] else { return }
            let left = list.filter { abs($0.t - t) > tol }
            guard left.count != list.count else { return }
            // The last key gone: its value becomes the static one, so the picture doesn't jump.
            if left.isEmpty, let last = list.first(where: { abs($0.t - t) <= tol }) {
                var tf = v.transform ?? E.Transform()
                switch prop {
                case .x: tf.x = last.v
                case .y: tf.y = last.v
                case .scale: tf.scale = last.v
                case .rotation: tf.rotation = last.v
                case .opacity: v.opacity = last.v
                case .volume: break
                case .exposure, .contrast, .saturation, .temperature, .tint:
                    var a = v.adjust ?? E.Adjust(); a[prop] = last.v == 0 ? nil : last.v; v.adjust = a == E.Adjust() ? nil : a
                }
                if [.x, .y, .scale, .rotation].contains(prop) { v.transform = tf }
            }
            k[prop] = left.isEmpty ? nil : left
            v.keyframes = k.isEmpty ? nil : k
        }
    }

    /// The timeline's Keyframe button: a key of every transform property (position, scale, rotation, opacity) at the
    /// playhead with the values shown there, as one undo step.
    @discardableResult
    public mutating func addKeyframesAll() -> Bool {
        guard selectedVisual != nil, let t = selectedLocalTime else { return false }
        var values: [E.KfProp: Double] = [:]
        for p in [E.KfProp.x, .y, .scale, .rotation, .opacity] { values[p] = visualValue(p) }
        return changeVisual { v in
            var k = v.keyframes ?? E.Keyframes()
            for (p, value) in values {
                var list = (k[p] ?? []).filter { abs($0.t - t) > 1e-6 }
                list.append(E.Keyframe(t: t, v: E.r6(value), ease: list.first?.ease ?? .easeInOut))
                list.sort { $0.t < $1.t }
                k[p] = list
            }
            v.keyframes = k
        }
    }

    /// The selected item's keyframe times (item time), all properties together, sorted.
    public var keyframeTimes: [Double] {
        guard let k = selectedVisual?.keyframes else { return [] }
        return Array(Set(k.present.flatMap { $0.1.map { E.r6($0.t) } })).sorted()
    }

    /// The timeline time of the selected item's next (`dir` > 0) or previous keyframe from the playhead, or nil.
    public func adjacentKeyframe(_ dir: Int) -> Double? {
        guard let s = selection, let loc = project.locate(s), let local = selectedLocalTime else { return nil }
        let track = project.tracks[loc.track]
        let start = E.itemSpan(project, track, track.items[loc.item]).startSec
        let t = dir > 0 ? keyframeTimes.first { $0 > local + 1e-4 } : keyframeTimes.last { $0 < local - 1e-4 }
        return t.map { E.r6(start + $0) }
    }

    // MARK: Crop

    /// Sets one side of the selected video's or picture's crop (0–0.45 of the source; nil/0 removes it).
    @discardableResult
    public mutating func setCrop(_ side: CropSide, _ value: Double) -> Bool {
        guard let v = selectedVisual, selectedItem?.textItem == nil else { return false }
        let x = E.r6(min(0.45, max(0, value)))
        var c = v.crop ?? E.Crop()
        switch side {
        case .left: c.left = x > 0 ? x : nil
        case .top: c.top = x > 0 ? x : nil
        case .right: c.right = x > 0 ? x : nil
        case .bottom: c.bottom = x > 0 ? x : nil
        }
        let empty = c.left == nil && c.top == nil && c.right == nil && c.bottom == nil
        return changeVisual { $0.crop = empty ? nil : c }
    }

    public enum CropSide: String, CaseIterable, Sendable { case left, top, right, bottom }

    /// Resets the selected item's crop, transform, opacity and keyframes.
    @discardableResult
    public mutating func resetTransform() -> Bool {
        changeVisual { v in v.crop = nil; v.transform = nil; v.opacity = nil; v.keyframes = nil }
    }

    // MARK: Mask and chroma key

    /// Changes the selected item's mask (no change without a mask).
    @discardableResult
    public mutating func changeMask(_ change: @escaping (inout E.Mask) -> Void) -> Bool {
        changeVisual { v in
            guard var m = v.mask else { return }
            change(&m)
            v.mask = m
        }
    }

    /// Changes the selected video's chroma key (no change without one).
    @discardableResult
    public mutating func changeChroma(_ change: @escaping (inout E.Chroma) -> Void) -> Bool {
        changeVisual { v in
            guard var c = v.chroma else { return }
            change(&c)
            v.chroma = c
        }
    }
}

// MARK: Translate captions (Mac Edit audit 2026-11-08: "Translate…" was a disabled placeholder)

extension EditSuite {
    /// A run of caption words translated together (a sentence, or up to 12 words / a 0.6 s pause): word indices and text.
    public struct CaptionChunk: Hashable, Sendable {
        public var indices: Range<Int>
        public var text: String
    }
}

extension EditSuiteState {
    /// The caption words in sentence-sized chunks, for translation.
    public var captionChunks: [EditSuite.CaptionChunk] {
        guard let words = project.captionTrack?.words, !words.isEmpty else { return [] }
        var out: [EditSuite.CaptionChunk] = []
        var start = 0
        for i in words.indices {
            let w = words[i]
            let last = i == words.count - 1
            let ends = w.text.hasSuffix(".") || w.text.hasSuffix("!") || w.text.hasSuffix("?")
            let gap = last ? 0 : words[i + 1].startSec - w.endSec
            if last || ends || gap > 0.6 || i - start + 1 >= 12 {
                out.append(EditSuite.CaptionChunk(indices: start..<(i + 1), text: words[start...i].map(\.text).joined(separator: " ")))
                start = i + 1
            }
        }
        return out
    }

    /// Replaces each chunk's words with its translation (same order as `captionChunks`), spread over the chunk's time by
    /// length, so the captions keep their timing and cuts still move them. One undo step. Empty translations keep the original.
    @discardableResult
    public mutating func translateCaptions(_ translations: [String]) -> Bool {
        let chunks = captionChunks
        guard let ct = project.captionTrack, chunks.count == translations.count, !chunks.isEmpty else { return false }
        var words: [E.CaptionWord] = []
        for (c, tr) in zip(chunks, translations) {
            let src = Array(ct.words[c.indices])
            let parts = tr.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty, let a = src.first?.startSec, let b = src.last?.endSec, b > a else { words += src; continue }
            let total = Double(parts.reduce(0) { $0 + $1.count + 1 })
            var t = a
            for p in parts {
                let d = (b - a) * Double(p.count + 1) / total
                words.append(E.CaptionWord(text: String(p.prefix(60)), startSec: E.r3(t), endSec: E.r3(min(b, t + d))))
                t += d
            }
        }
        let capped = Array(words.prefix(E.maxWords))
        return apply { p in
            guard let i = p.tracks.firstIndex(where: { $0.kind == .caption && $0.caption != nil }) else { return nil }
            var q = p
            q.tracks[i].caption!.words = capped
            return q
        }
    }
}

// MARK: Volume keyframes (parity wave 1)

extension EditSuiteState {
    /// Changes the selected video or audio clip's keyframes.
    private mutating func changeSoundKeys(_ change: @escaping (inout E.Keyframes) -> Void) -> Bool {
        changeSelected { it in
            switch it {
            case .video(var c): var k = c.keyframes ?? E.Keyframes(); change(&k); c.keyframes = k.isEmpty ? nil : k; it = .video(c)
            case .audio(var c): var k = c.keyframes ?? E.Keyframes(); change(&k); c.keyframes = k.isEmpty ? nil : k; it = .audio(c)
            default: break
            }
        }
    }

    private var selectedVolumeKeys: [E.Keyframe]? {
        switch selectedItem {
        case .video(let c): return c.keyframes?.volume
        case .audio(let c): return c.keyframes?.volume
        default: return nil
        }
    }

    /// The selected clip's volume at the playhead (its volume keys there when it has any), 0–2.
    public var volumeAtPlayhead: Double? {
        guard let snd = selectedSound else { return nil }
        if let keys = selectedVolumeKeys, !keys.isEmpty, let t = selectedLocalTime { return E.keyframeValue(keys, t) }
        return snd.volume ?? 1
    }

    public var hasVolumeKeys: Bool { !(selectedVolumeKeys?.isEmpty ?? true) }

    /// Whether there is a volume key at the playhead (within half a frame).
    public var hasVolumeKeyHere: Bool {
        guard let keys = selectedVolumeKeys, let t = selectedLocalTime else { return false }
        return keys.contains { abs($0.t - t) <= 0.5 / max(1, project.canvas.fps) }
    }

    /// The Volume slider: with volume keys it sets the key at the playhead, else the clip's volume (nil at 1×).
    @discardableResult
    public mutating func setVolumeValue(_ gain: Double) -> Bool {
        let g = E.r6(min(2, max(0, gain)))
        if hasVolumeKeys { return addVolumeKey(g) }
        return changeSound { $0.volume = abs(g - 1) < 1e-6 ? nil : g }
    }

    /// Adds (or replaces) a volume key at the playhead; the value defaults to the level heard there.
    @discardableResult
    public mutating func addVolumeKey(_ gain: Double? = nil) -> Bool {
        guard let t = selectedLocalTime, let v = gain ?? volumeAtPlayhead else { return false }
        let tol = 0.5 / max(1, project.canvas.fps)
        return changeSoundKeys { k in
            var list = (k.volume ?? []).filter { abs($0.t - t) > tol }
            list.append(E.Keyframe(t: t, v: E.r6(min(2, max(0, v))), ease: list.first?.ease ?? .linear))
            list.sort { $0.t < $1.t }
            k.volume = list
        }
    }

    /// Removes the volume key at the playhead; the last one's level becomes the clip's volume.
    @discardableResult
    public mutating func removeVolumeKey() -> Bool {
        guard let t = selectedLocalTime, let keys = selectedVolumeKeys else { return false }
        let tol = 0.5 / max(1, project.canvas.fps)
        let left = keys.filter { abs($0.t - t) > tol }
        guard left.count != keys.count else { return false }
        let last = keys.first { abs($0.t - t) <= tol }!.v
        return changeSelected { it in
            switch it {
            case .video(var c):
                if left.isEmpty { c.volume = abs(last - 1) < 1e-6 ? nil : last }
                var k = c.keyframes ?? E.Keyframes(); k.volume = left.isEmpty ? nil : left; c.keyframes = k.isEmpty ? nil : k
                it = .video(c)
            case .audio(var c):
                if left.isEmpty { c.volume = abs(last - 1) < 1e-6 ? nil : last }
                var k = c.keyframes ?? E.Keyframes(); k.volume = left.isEmpty ? nil : left; c.keyframes = k.isEmpty ? nil : k
                it = .audio(c)
            default: break
            }
        }
    }
}

// MARK: Wave 1 contract: mirror, freeze frame, blend, background fill, fit

extension EditSuiteState {
    /// Mirror the selected item (video, picture or text) horizontally and/or vertically (nil leaves that axis).
    @discardableResult
    public mutating func setFlip(x: Bool? = nil, y: Bool? = nil) -> Bool {
        changeVisual { v in
            var tf = v.transform ?? E.Transform()
            if let x { tf.flipX = x ? true : nil }
            if let y { tf.flipY = y ? true : nil }
            v.transform = tf
        }
    }

    public var selectedFlip: (x: Bool, y: Bool) {
        let tf = selectedVisual?.transform
        return (tf?.flipX == true, tf?.flipY == true)
    }

    /// Freeze frame at the playhead (ops.ts `freeze`): the main clip there is cut at that frame and a hold of it (durationSec,
    /// 0.1–30 s, silent) goes between the two pieces. The hold is selected.
    @discardableResult
    public mutating func freezeFrame(durationSec: Double = 1) -> Bool {
        let at = playhead
        let dur = E.r3(min(E.holdMaxSec, max(E.holdMinSec, durationSec)))
        var holdId: String?
        let ok = apply { p in
            guard let mi = p.tracks.firstIndex(where: { $0.kind == .main }) else { return nil }
            let spans = E.timeline(p)
            guard let k = spans.firstIndex(where: { at >= $0.startSec && at < $0.endSec }), case .video(let c) = p.tracks[mi].items[k] else { return nil }
            let local = at - spans[k].startSec, src = E.clipSourceAt(c, local)
            let dur0 = p.asset(c.asset)?.durationSec ?? c.outSec
            let frame = E.r3(min(src, dur0 - E.minClipSourceSec))
            var q = p
            var hold = c
            hold.id = q.newId("c")
            hold.inSec = frame; hold.outSec = E.r3(frame + E.minClipSourceSec); hold.speed = 1; hold.holdSec = dur
            hold.transitionIn = nil; hold.speedCurve = nil; hold.keyframes = nil; hold.fadeInSec = nil; hold.fadeOutSec = nil
            if local >= 0.05, spans[k].endSec - at >= 0.05, c.holdSec == nil,
               src - c.inSec >= E.minClipSourceSec, c.outSec - src >= E.minClipSourceSec {
                // Cut the clip at the frame; the hold goes between the two pieces.
                var a = c, b = c
                let x = (src - c.inSec) / (c.outSec - c.inSec)
                a.outSec = E.r6(src)
                b.inSec = E.r6(src); b.transitionIn = nil
                if let sc = c.speedCurve { a.speedCurve = E.subCurve(sc, 0, x); b.speedCurve = E.subCurve(sc, x, 1) }
                q.tracks[mi].items.replaceSubrange(k...k, with: [.video(a), .video(hold)])
                b.id = q.newId("c")
                q.tracks[mi].items.insert(.video(b), at: k + 2)
            } else {
                q.tracks[mi].items.insert(.video(hold), at: local < 0.05 && c.holdSec == nil ? k : k + 1)
            }
            q.tracks[mi].items = E.Project.fixTransitions(q.tracks[mi].items)
            holdId = hold.id
            return q
        }
        if ok { selection = holdId }
        return ok
    }

    /// A freeze frame's length (the selected hold).
    @discardableResult
    public mutating func setHoldDuration(_ sec: Double) -> Bool {
        let d = E.r3(min(E.holdMaxSec, max(E.holdMinSec, sec)))
        return changeVideo { c in if c.holdSec != nil { c.holdSec = d } }
    }

    /// Blend mode of the selected overlay (video or picture on an overlay row); normal clears it.
    @discardableResult
    public mutating func setBlend(_ mode: E.BlendMode) -> Bool {
        guard let t = selectedTrack, t.kind == .video || t.kind == .image else { return false }
        return changeSelected { it in
            switch it {
            case .video(var c): c.blend = mode == .normal ? nil : mode; it = .video(c)
            case .image(var c): c.blend = mode == .normal ? nil : mode; it = .image(c)
            default: break
            }
        }
    }

    public var selectedBlend: E.BlendMode? {
        guard let t = selectedTrack, t.kind == .video || t.kind == .image else { return nil }
        switch selectedItem {
        case .video(let c): return c.blend ?? .normal
        case .image(let c): return c.blend ?? .normal
        default: return nil
        }
    }

    /// The background behind contain-fitted clips: a colour, or a blurred copy of the clip (ops.ts `fill`).
    @discardableResult
    public mutating func setBackground(fill: E.CanvasFill, color: String? = nil) -> Bool {
        apply { p in
            var q = p
            if let color { q.canvas.background = color }
            q.canvas.fill = fill == .blur ? .blur : nil
            return q == p ? nil : q
        }
    }

    /// Fit (contain) or fill (cover) for the selected video or picture.
    @discardableResult
    public mutating func setFit(_ fit: E.Fit) -> Bool {
        changeSelected { it in
            switch it {
            case .video(var c): c.fit = fit; it = .video(c)
            case .image(var c): c.fit = fit; it = .image(c)
            default: break
            }
        }
    }
}

// MARK: Overlay ⇄ main track (parity, as Android's SuiteOps.toMain / toOverlay)

extension EditSuiteState {
    /// Whether the selected clip can move to the other kind of track: an overlay clip to main, or a main clip (not the last
    /// one) to an overlay track.
    public var selectedTrackSwap: (toMain: Bool, possible: Bool)? {
        guard let t = selectedTrack, selectedVideo != nil else { return nil }
        if t.kind == .video { return (true, true) }
        if t.kind == .main { return (false, t.items.count >= 2) }
        return nil
    }

    /// "Move to main track": the overlay clip goes to the main-track clip boundary nearest where it starts, filling the frame
    /// there (its overlay placing, keyframes, opacity, blend, mask, chroma key and cut-out are dropped; trim, speed, sound and
    /// look stay). An overlay track left empty goes.
    @discardableResult
    public mutating func moveToMain() -> Bool {
        guard let id = selection else { return false }
        let ok = apply { p in
            guard let (ti, ii) = p.locate(id), p.tracks[ti].kind == .video, case .video(var c) = p.tracks[ti].items[ii], let main = p.mainTrack else { return nil }
            let tid = p.tracks[ti].id
            let start = E.itemSpan(p, p.tracks[ti], p.tracks[ti].items[ii]).startSec
            let bounds = [0.0] + E.timeline(p).map(\.endSec)
            let at = bounds.indices.min { abs(bounds[$0] - start) < abs(bounds[$1] - start) } ?? bounds.count - 1
            c.startSec = nil; c.fit = nil; c.transform = nil; c.keyframes = nil; c.opacity = nil; c.blend = nil
            c.mask = nil; c.chroma = nil; c.alphaMatte = nil
            guard var q = p.removing(id) else { return nil }
            if q.track(tid)?.items.isEmpty == true { q = q.removingTrack(tid) ?? q }
            return q.adding(.video(c), toTrack: main.id, index: at)
        }
        if ok { selection = id }
        return ok
    }

    /// "Move to an overlay track": the main clip plays at the time it played (the main track closes the gap), full frame, on
    /// the first overlay track it fits on, or a new one named "Overlay". The main track keeps at least one clip.
    @discardableResult
    public mutating func moveToOverlay() -> Bool {
        guard let id = selection else { return false }
        let ok = apply { p in
            guard let (ti, ii) = p.locate(id), p.tracks[ti].kind == .main, p.tracks[ti].items.count >= 2,
                  case .video(var c) = p.tracks[ti].items[ii] else { return nil }
            let span = E.itemSpan(p, p.tracks[ti], p.tracks[ti].items[ii])
            guard var q = p.removing(id) else { return nil }
            c.startSec = E.r6(span.startSec)
            c.transitionIn = nil
            for t in q.tracks where t.kind == .video {
                if let r = q.adding(.video(c), toTrack: t.id) { return r }
            }
            guard let r = q.addingTrack(.video, name: "Overlay") else { return nil }
            q = r.project
            return q.adding(.video(c), toTrack: r.trackId)
        }
        if ok { selection = id } else if selectedTrack?.kind == .main, (selectedTrack?.items.count ?? 0) < 2 {
            refuse("The main track needs at least one clip")
        }
        return ok
    }
}
