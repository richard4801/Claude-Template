import Foundation

// Parity rows Android built app-side (WS8 22a950d, f90b4f3), ported so the Mac does the same with the same rules: slip, set
// a clip's length, replace a clip, manual beat marks, another take's sound, loop a sound, the look's effects, split screen,
// cut clips to the beat and even out volume. Pure state operations (one undo step each), tested in EditSuiteParityTests.

extension EditSuite {
    /// Split-screen layouts: each cell as (centre x, centre y, width, height), fractions of the canvas.
    public enum SplitLayout: String, CaseIterable, Sendable, Identifiable {
        case sideBySide, topBottom, three, grid
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .sideBySide: return "Side by side"
            case .topBottom: return "Top and bottom"
            case .three: return "Three rows"
            case .grid: return "Grid of four"
            }
        }
        public var cells: [[Double]] {
            switch self {
            case .sideBySide: return [[0.25, 0.5, 0.5, 1], [0.75, 0.5, 0.5, 1]]
            case .topBottom: return [[0.5, 0.25, 1, 0.5], [0.5, 0.75, 1, 0.5]]
            case .three: return [[0.5, 1 / 6.0, 1, 1 / 3.0], [0.5, 0.5, 1, 1 / 3.0], [0.5, 5 / 6.0, 1, 1 / 3.0]]
            case .grid: return [[0.25, 0.25, 0.5, 0.5], [0.75, 0.25, 0.5, 0.5], [0.25, 0.75, 0.5, 0.5], [0.75, 0.75, 0.5, 0.5]]
            }
        }
    }

    /// The look's effects the Adjust panel edits (0 removes the effect; vignette −1…1, the rest 0–1).
    public enum LookEffect: String, CaseIterable, Sendable, Identifiable {
        case vignette, sharpen, fade, chromatic, halation, leak
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .vignette: return "Vignette"
            case .sharpen: return "Sharpen"
            case .fade: return "Fade"
            case .chromatic: return "Colour fringe"
            case .halation: return "Glow"
            case .leak: return "Light leak"
            }
        }
        public var range: ClosedRange<Double> { self == .vignette ? -1...1 : 0...1 }
    }
}

extension EditSuiteState {
    private static func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private static func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

    /// The selected main clip, else the one under the playhead.
    public var activeMainClip: E.VideoClip? {
        if let c = selectedVideo, selectedIsMain { return c }
        return project.mainClip(at: playhead).map { project.mainClips[$0.index] }
    }

    // MARK: Slip and length

    /// Slip: the main clip plays another part of its source from `inSec`, keeping its length.
    @discardableResult
    public mutating func slip(to inSec: Double) -> Bool {
        guard let c = activeMainClip, c.holdSec == nil, let dur = project.asset(c.asset)?.durationSec else { return false }
        let len = c.outSec - c.inSec
        let i = Self.r3(min(max(0, inSec), max(0, dur - len)))
        return apply { $0.updating(c.id) { it in if case .video(var v) = it { v.inSec = i; v.outSec = Self.r3(i + len); it = .video(v) } } }
    }

    /// Set the length of the selected video clip on the timeline; its speed follows (0.1–10×). A freeze frame changes its hold.
    @discardableResult
    public mutating func setClipLength(_ sec: Double) -> Bool {
        guard let c = selectedVideo else { return false }
        if c.holdSec != nil { return setHoldDuration(sec) }
        guard c.speedCurve == nil, sec > 0 else { return false }
        let sp = (c.outSec - c.inSec) / sec
        return setSpeed(sp)
    }

    // MARK: Replace

    /// Replace: the main clip plays `asset` (another take) instead, from its start, for the same source length where it is
    /// long enough (else the whole take); speed, look, transform, sound settings and transition stay.
    @discardableResult
    public mutating func replaceClip(with asset: E.Asset) -> Bool {
        guard let c = activeMainClip, asset.kind == .video, let d = asset.durationSec, d >= E.minClipSourceSec else { return false }
        let ok = apply { p in
            let existing = p.assets.first { $0.take != nil && $0.take == asset.take && $0.kind == .video }
            var q = existing == nil ? p.addingAsset(asset) : p
            let aid = existing?.id ?? asset.id
            let len = c.holdSec != nil ? E.minClipSourceSec : min(c.outSec - c.inSec, d)
            q = q.updating(c.id) { it in
                guard case .video(var v) = it else { return }
                v.asset = aid; v.inSec = 0; v.outSec = Self.r3(len); v.audioAsset = nil; v.alphaMatte = nil; E.dropLayers(&v)
                it = .video(v)
            } ?? q
            return q
        }
        if !ok, lastRefusal == nil { refuse("That video is too short to replace this clip") }
        return ok
    }

    // MARK: Beats, take sound, loop

    /// The music clip selected, else the one under the playhead.
    public var musicHere: (trackId: String, clip: E.AudioClip)? {
        if let s = selection {
            for t in project.tracks where t.kind == .music { for case .audio(let c) in t.items where c.id == s { return (t.id, c) } }
        }
        for t in project.tracks where t.kind == .music {
            for it in t.items {
                let sp = E.itemSpan(project, t, it)
                if playhead >= sp.startSec && playhead < sp.endSec, case .audio(let c) = it { return (t.id, c) }
            }
        }
        return nil
    }

    /// A beat mark at the playhead on the music under it (it snaps like detected ones).
    @discardableResult
    public mutating func markBeat() -> Bool {
        guard let (tid, m) = musicHere, let t = project.track(tid) else { refuse("Move the playhead over the music to mark a beat"); return false }
        let sp = E.itemSpan(project, t, .audio(m))
        let src = Self.r3(m.inSec + (playhead - sp.startSec) * (m.speed ?? 1))
        return apply { $0.updating(m.id) { it in
            guard case .audio(var c) = it else { return }
            c.beats = ((c.beats ?? []).filter { abs($0 - src) > 0.02 } + [src]).sorted()
            it = .audio(c)
        } }
    }

    /// Removes every beat mark of the music here.
    @discardableResult
    public mutating func clearBeats() -> Bool {
        guard let (_, m) = musicHere, m.beats != nil || m.strongBeats != nil else { return false }
        return apply { $0.updating(m.id) { it in if case .audio(var c) = it { c.beats = nil; c.strongBeats = nil; it = .audio(c) } } }
    }

    /// Another take's sound (its video file, sound only) at the playhead on a sound effects track.
    @discardableResult
    public mutating func addTakeSound(_ asset: E.Asset) -> Bool {
        guard asset.kind == .video, let d = asset.durationSec else { return false }
        var newId: String?
        let at = playhead
        let ok = apply { p in
            let existing = p.assets.first { $0.take != nil && $0.take == asset.take && $0.kind == .video }
            var q = existing == nil ? p.addingAsset(asset) : p
            let aid = existing?.id ?? asset.id
            let end = E.durationSec(q)
            let start = Self.r3(min(max(0, at), max(0, end - 0.1)))
            let len = Self.r3(min(d, max(0.1, end - start)))
            let id = q.newId("s")
            let clip = E.AudioClip(id: id, asset: aid, startSec: start, inSec: 0, outSec: len)
            for t in q.tracks where t.kind == .sfx {
                if let r = q.adding(.audio(clip), toTrack: t.id) { newId = id; return r }
            }
            guard let r = q.addingTrack(.sfx, name: "Sound") else { return nil }
            q = r.project
            newId = id
            return q.adding(.audio(clip), toTrack: r.trackId)
        }
        if ok { selection = newId } else if lastRefusal == nil { refuse("No room for that sound there") }
        return ok
    }

    /// The selected sound repeated back to back until the video's end (each copy as long as the original, the last cut short).
    @discardableResult
    public mutating func loopToEnd() -> Bool {
        guard case .audio(let c)? = selectedItem, let loc = project.locate(c.id) else { refuse("Select a sound on the timeline to loop it"); return false }
        let tid = project.tracks[loc.track].id
        let ok = apply { p in
            let end = E.durationSec(p)
            let len = E.clipLength(c)
            var at = c.startSec + len
            var cur = p
            var n = 2
            while at < end - 0.1 && n < 200 {
                let l = min(len, end - at)
                var copy = c
                copy.id = cur.newId(c.id + ".")
                copy.startSec = Self.r3(at)
                copy.outSec = Self.r3(c.inSec + l * (c.speed ?? 1))
                copy.fadeInSec = nil
                guard let next = cur.adding(.audio(copy), toTrack: tid) else { break }
                cur = next
                at += l
                n += 1
            }
            return cur == p ? nil : cur
        }
        if !ok, lastRefusal == nil { refuse("Nothing to loop: it already reaches the end") }
        return ok
    }

    // MARK: The look's effects

    /// The value of one of the look's effects on the selected picture (0 when it has none).
    public func lookEffect(_ e: EditSuite.LookEffect) -> Double {
        let l = selectedVisual?.look
        switch e {
        case .vignette: return l?.vignette?.amount ?? 0
        case .sharpen: return l?.sharpen ?? 0
        case .fade: return l?.lift ?? 0
        case .chromatic: return l?.chromatic ?? 0
        case .halation: return l?.halation?.amount ?? 0
        case .leak: return l?.leak?.amount ?? 0
        }
    }

    /// Sets one of the look's effects (0 removes it) on the selected video or picture.
    @discardableResult
    public mutating func setLookEffect(_ e: EditSuite.LookEffect, _ value: Double) -> Bool {
        let v = Self.r3(min(e.range.upperBound, max(e.range.lowerBound, value)))
        return changeVisual { vis in
            var l = vis.look ?? E.Look()
            let on = abs(v) > 0.0005
            switch e {
            case .vignette: l.vignette = on ? E.Vignette(amount: v, size: l.vignette?.size, softness: l.vignette?.softness) : nil
            case .sharpen: l.sharpen = on ? v : nil
            case .fade: l.lift = on ? v : nil
            case .chromatic: l.chromatic = on ? v : nil
            case .halation: l.halation = on ? E.Halation(amount: v, radius: l.halation?.radius, threshold: l.halation?.threshold) : nil
            case .leak: l.leak = on ? E.Leak(kind: l.leak?.kind ?? .warm, amount: v, angle: l.leak?.angle) : nil
            }
            vis.look = l == E.Look() ? nil : l
        }
    }

    // MARK: Split screen

    /// The video clips on screen at the playhead: the main clip, then overlays from the bottom track up.
    public var clipsHere: [E.VideoClip] {
        var out: [E.VideoClip] = []
        if let m = project.mainClip(at: playhead) { out.append(project.mainClips[m.index]) }
        for t in project.tracks where t.kind == .video && t.hidden != true {
            for it in t.items {
                let sp = E.itemSpan(project, t, it)
                if playhead >= sp.startSec - 1e-9, playhead < sp.endSec - 1e-9, case .video(let c) = it { out.append(c) }
            }
        }
        return out
    }

    /// Split screen: the clips on screen at the playhead placed into the layout's cells, each cropped (centred) to its cell's
    /// shape and fitted whole into it (crop + contain fit + transform, so each stays editable). Needs two clips.
    @discardableResult
    public mutating func splitScreen(_ layout: EditSuite.SplitLayout) -> Bool {
        let ids = clipsHere.map(\.id)
        guard ids.count >= 2 else { refuse("Split screen needs two clips on screen: add an overlay at the playhead"); return false }
        return apply { p in
            let W = Double(p.canvas.width), H = Double(p.canvas.height)
            var q = p
            for (k, id) in ids.prefix(layout.cells.count).enumerated() {
                let cell = layout.cells[k]
                guard let loc = q.locate(id), case .video(let c) = q.tracks[loc.track].items[loc.item] else { return nil }
                let a = q.asset(c.asset)
                let sw = Double(a?.width ?? p.canvas.width), sh = Double(a?.height ?? p.canvas.height)
                let cellA = (cell[2] * W) / (cell[3] * H)
                var l = 0.0, t = 0.0
                if sw / sh > cellA { l = (1 - (sh * cellA) / sw) / 2 } else { t = (1 - (sw / cellA) / sh) / 2 }
                if l > 0.45 + 1e-9 || t > 0.45 + 1e-9 { return nil }
                let crop: E.Crop? = (l > 1e-6 || t > 1e-6)
                    ? E.Crop(left: l > 0 ? Self.r4(l) : nil, top: t > 0 ? Self.r4(t) : nil, right: l > 0 ? Self.r4(l) : nil, bottom: t > 0 ? Self.r4(t) : nil) : nil
                let fw = min(W, H * cellA)
                let tf = E.Transform(x: Self.r4(cell[0]), y: Self.r4(cell[1]), scale: Self.r4(cell[2] * W / fw), rotation: nil,
                                     flipX: c.transform?.flipX, flipY: c.transform?.flipY)
                q = q.updating(id) { it in
                    guard case .video(var v) = it else { return }
                    v.fit = .contain; v.crop = crop; v.transform = tf
                    if var kf = v.keyframes { kf.x = nil; kf.y = nil; kf.scale = nil; kf.rotation = nil; v.keyframes = kf.isEmpty ? nil : kf }
                    it = .video(v)
                } ?? q
            }
            return q
        }
    }

    // MARK: Cut to the beat, even out volume

    /// Beat-synced cut: each main clip, in order, ends on the beat nearest where it ends now (at least `minSec` long),
    /// trimming its out point (a freeze frame: its length). A clip whose source can't reach that beat ends on the latest
    /// beat it can; clips with a speed curve stay. Returns how many changed (0 = nothing to do).
    @discardableResult
    public mutating func cutToBeats(minSec: Double = 0.3) -> Int {
        let marks = beats.map(\.t)
        guard !marks.isEmpty else { refuse("Detect or mark beats on the music first"); return 0 }
        var changed = 0
        _ = apply { p in
            var q = p
            for i in p.mainClips.indices {
                let spans = E.timeline(q)
                guard i < spans.count else { break }
                let span = spans[i], c = q.mainClips[i]
                if c.speedCurve != nil { continue }
                let cands = marks.filter { $0 >= span.startSec + minSec - 1e-9 }
                if cands.isEmpty { break }
                let maxLen = c.holdSec != nil ? E.holdMaxSec : ((q.asset(c.asset)?.durationSec ?? c.outSec) - c.inSec) / c.speed
                guard let end = cands.filter({ $0 - span.startSec <= maxLen + 1e-9 }).min(by: { abs($0 - span.endSec) < abs($1 - span.endSec) }),
                      abs(end - span.endSec) >= 1e-6 else { continue }
                let len = end - span.startSec
                let next = q.updating(c.id) { it in
                    guard case .video(var v) = it else { return }
                    if v.holdSec != nil { v.holdSec = min(E.holdMaxSec, max(E.holdMinSec, Self.r3(len))) } else { v.outSec = E.r6(v.inSec + len * v.speed) }
                    it = .video(v)
                }
                if let next { q = next; changed += 1 }
            }
            if let mi = q.tracks.firstIndex(where: { $0.kind == .main }) { q.tracks[mi].items = E.Project.fixTransitions(q.tracks[mi].items) }
            return changed > 0 ? q : nil
        }
        return changed
    }

    /// Even out volume: every unmuted main and voice clip with measurable sound gets the volume that brings its level to the
    /// median level, between 0.25× and 2×, never past 0.98 of full scale at its loudest. `levels` = each clip's (RMS above the
    /// silence gate, loudest peak) over the part that plays, measured by the app. Music is left to ducking; clips with volume
    /// keyframes keep them. Returns how many clips changed.
    @discardableResult
    public mutating func evenVolume(levels: [String: (rms: Double, peak: Double)]) -> Int {
        var ms: [(id: String, rms: Double, peak: Double)] = []
        for t in project.tracks where t.muted != true && (t.kind == .main || t.kind == .voice) {
            for it in t.items {
                switch it {
                case .video(let c) where c.muted != true && c.keyframes?.volume == nil && c.holdSec == nil:
                    if let l = levels[c.id], l.rms > 0 { ms.append((c.id, l.rms, l.peak)) }
                case .audio(let c) where c.muted != true && c.keyframes?.volume == nil:
                    if let l = levels[c.id], l.rms > 0 { ms.append((c.id, l.rms, l.peak)) }
                default: break
                }
            }
        }
        guard ms.count >= 2 else { refuse("Even out volume needs two or more clips with sound"); return 0 }
        let sorted = ms.map(\.rms).sorted()
        let target = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        var changed = 0
        _ = apply { p in
            var q = p
            for m in ms {
                let g = (max(0, min(min(2, max(0.25, target / m.rms)), 0.98 / max(1e-6, m.peak))) * 100).rounded() / 100
                let vol: Double? = abs(g - 1) > 0.005 ? g : nil
                guard let next = q.updating(m.id, { it in
                    switch it {
                    case .video(var c): c.volume = vol; it = .video(c)
                    case .audio(var c): c.volume = vol; it = .audio(c)
                    default: break
                    }
                }), next != q else { continue }
                q = next
                changed += 1
            }
            return changed > 0 ? q : nil
        }
        return changed
    }
}
