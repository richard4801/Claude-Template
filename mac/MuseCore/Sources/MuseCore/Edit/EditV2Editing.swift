import Foundation

// A small immutable editing API over v2 projects for the editor screens (which wait for the Figma review): each operation
// returns a new project, or nil when it can't apply (the project is left as it was). EditV2.History adds undo / redo like
// the v1 EditHistory.

extension EditV2.Project {

    /// Every id in use (assets, tracks, items).
    public var allIds: Set<String> {
        var s = Set(assets.map(\.id))
        for t in tracks {
            s.insert(t.id)
            for it in t.items { s.insert(it.id) }
        }
        return s
    }

    /// A fresh id: `prefix` + the smallest number not in use.
    public func newId(_ prefix: String) -> String {
        let used = allIds
        var n = 1
        while used.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    /// Where an item is: (track index, item index).
    public func locate(_ itemId: String) -> (track: Int, item: Int)? {
        for (ti, t) in tracks.enumerated() {
            if let ii = t.items.firstIndex(where: { $0.id == itemId }) { return (ti, ii) }
        }
        return nil
    }

    private static func fits(_ items: [EditV2.Item], _ candidate: EditV2.Item, skipping id: String? = nil) -> Bool {
        let s = candidate.startSec, e = s + candidate.lengthSec
        return !items.contains { it in
            guard it.id != id else { return false }
            let a = it.startSec, b = a + it.lengthSec
            return s < b - EditV2.overlapSlackSec && a < e - EditV2.overlapSlackSec
        }
    }

    /// Adds an asset (replacing one with the same id).
    public func addingAsset(_ a: EditV2.Asset) -> EditV2.Project {
        var p = self
        if let i = p.assets.firstIndex(where: { $0.id == a.id }) { p.assets[i] = a } else { p.assets.append(a) }
        return p
    }

    /// Adds an empty track of `kind` on top of the others (not a second main or caption track).
    public func addingTrack(_ kind: EditV2.TrackKind, id: String? = nil, name: String? = nil) -> (project: EditV2.Project, trackId: String)? {
        if kind == .main || (kind == .caption && tracks.contains { $0.kind == .caption }) || tracks.count >= EditV2.maxTracks { return nil }
        let tid = id ?? newId(kind.rawValue)
        guard !allIds.contains(tid) else { return nil }
        var p = self
        p.tracks.append(EditV2.Track(id: tid, kind: kind, name: name))
        return (p, tid)
    }

    public func removingTrack(_ id: String) -> EditV2.Project? {
        guard let i = tracks.firstIndex(where: { $0.id == id }), tracks[i].kind != .main else { return nil }
        var p = self
        p.tracks.remove(at: i)
        return p
    }

    /// Adds an item to a track. Main clips go at `index` (default: the end) and lose any startSec; other items are put in
    /// startSec order and must not overlap the track's items. The item's kind must suit the track.
    public func adding(_ item: EditV2.Item, toTrack trackId: String, index: Int? = nil) -> EditV2.Project? {
        guard let ti = tracks.firstIndex(where: { $0.id == trackId }), !allIds.contains(item.id) else { return nil }
        let kind = tracks[ti].kind
        var p = self
        switch (kind, item) {
        case (.main, .video(var c)):
            c.startSec = nil
            let at = min(max(0, index ?? p.tracks[ti].items.count), p.tracks[ti].items.count)
            if at == 0 { c.transitionIn = nil }
            p.tracks[ti].items.insert(.video(c), at: at)
            return p
        case (.video, .video), (.image, .image), (.text, .text), (.music, .audio), (.voice, .audio), (.sfx, .audio):
            guard Self.fits(p.tracks[ti].items, item) else { return nil }
            let at = p.tracks[ti].items.firstIndex { $0.startSec > item.startSec } ?? p.tracks[ti].items.count
            p.tracks[ti].items.insert(item, at: at)
            return p
        default:
            return nil
        }
    }

    /// Removes an item; the main track keeps at least one clip. The clip after a removed main clip loses its transition when
    /// it becomes the first or no longer fits.
    public func removing(_ itemId: String) -> EditV2.Project? {
        guard let (ti, ii) = locate(itemId) else { return nil }
        if tracks[ti].kind == .main && tracks[ti].items.count <= 1 { return nil }
        var p = self
        p.tracks[ti].items.remove(at: ii)
        if p.tracks[ti].kind == .main { p.tracks[ti].items = Self.fixTransitions(p.tracks[ti].items) }
        return p
    }

    /// Moves a non-main item to `startSec` (and optionally to another track of a suitable kind) when it fits there.
    public func moving(_ itemId: String, toStartSec start: Double, track trackId: String? = nil) -> EditV2.Project? {
        guard let (ti, ii) = locate(itemId), tracks[ti].kind != .main, start >= 0 else { return nil }
        var item = tracks[ti].items[ii]
        item.startSec = start
        var p = self
        p.tracks[ti].items.remove(at: ii)
        let dest = trackId ?? tracks[ti].id
        guard let di = p.tracks.firstIndex(where: { $0.id == dest }), p.tracks[di].kind != .main else { return nil }
        guard Self.fits(p.tracks[di].items, item) else { return nil }
        switch (p.tracks[di].kind, item) {
        case (.video, .video), (.image, .image), (.text, .text), (.music, .audio), (.voice, .audio), (.sfx, .audio): break
        default: return nil
        }
        let at = p.tracks[di].items.firstIndex { $0.startSec > start } ?? p.tracks[di].items.count
        p.tracks[di].items.insert(item, at: at)
        return p
    }

    /// Moves a main clip to another place in the main track.
    public func movingMainClip(_ itemId: String, to index: Int) -> EditV2.Project? {
        guard let (ti, ii) = locate(itemId), tracks[ti].kind == .main else { return nil }
        let n = tracks[ti].items.count
        let to = min(max(0, index), n - 1)
        guard to != ii else { return nil }
        var p = self
        let it = p.tracks[ti].items.remove(at: ii)
        p.tracks[ti].items.insert(it, at: to)
        p.tracks[ti].items = Self.fixTransitions(p.tracks[ti].items)
        return p
    }

    /// Replaces an item (same id, same kind of item) after `change`.
    public func updating(_ itemId: String, _ change: (inout EditV2.Item) -> Void) -> EditV2.Project? {
        guard let (ti, ii) = locate(itemId) else { return nil }
        var p = self
        var it = p.tracks[ti].items[ii]
        change(&it)
        guard it.id == itemId else { return nil }
        p.tracks[ti].items[ii] = it
        if p.tracks[ti].kind != .main {
            p.tracks[ti].items = EditV2.stableSorted(p.tracks[ti].items) { $0.startSec < $1.startSec }
        }
        return p == self ? nil : p
    }

    /// Sets (or with nil removes) the transition into a main clip: not on the first clip, 0.1–2 s, at most half of it and of
    /// the clip before.
    public func settingTransition(_ itemId: String, _ tr: EditV2.Transition?) -> EditV2.Project? {
        guard let (ti, ii) = locate(itemId), tracks[ti].kind == .main, case .video(var c) = tracks[ti].items[ii] else { return nil }
        if let tr {
            guard ii > 0, tr.durationSec >= EditV2.minTransitionSec - 1e-9, tr.durationSec <= EditV2.maxTransitionSec + 1e-9,
                  tr.durationSec <= EditV2.clipLength(c) / 2 + 1e-9, tr.durationSec <= tracks[ti].items[ii - 1].lengthSec / 2 + 1e-9 else { return nil }
        }
        guard c.transitionIn != tr else { return nil }
        c.transitionIn = tr
        var p = self
        p.tracks[ti].items[ii] = .video(c)
        return p
    }

    /// The main clip at timeline t (in a transition overlap, the incoming one) and t in its own time.
    public func mainClip(at t: Double) -> (index: Int, local: Double)? {
        let spans = EditV2.timeline(self)
        guard !spans.isEmpty else { return nil }
        var i = 0
        for (k, s) in spans.enumerated() where s.startSec <= t + 1e-9 { i = k }
        return (i, max(0, t - spans[i].startSec))
    }

    /// Splits the main clip under timeline time t there (snapped to a frame at the canvas fps). Both pieces keep at least
    /// 0.1 s of source and every transition still fits. The first piece keeps the id, transition and fade-in; the second gets
    /// a new id and the fade-out; keyframes are cut at the split (each piece gets a key at the cut).
    public func splittingMainClip(at t: Double) -> (project: EditV2.Project, newId: String)? {
        guard let mi = tracks.firstIndex(where: { $0.kind == .main }), let (i, rawLocal) = mainClip(at: t),
              case .video(let c) = tracks[mi].items[i] else { return nil }
        let fps = canvas.fps > 0 ? canvas.fps : 30
        let local = (rawLocal * fps).rounded() / fps
        let src = EditV2.r6(EditV2.clipSourceAt(c, local))
        guard src - c.inSec >= EditV2.minClipSourceSec - 1e-9, c.outSec - src >= EditV2.minClipSourceSec - 1e-9 else { return nil }
        var a = c, b = c
        let nid = newId(c.id + ".")
        a.outSec = src
        a.fadeOutSec = nil
        if let sc = c.speedCurve {
            // Each half keeps its part of the curve (preset becomes custom).
            let x = (src - c.inSec) / (c.outSec - c.inSec)
            a.speedCurve = EditV2.subCurve(sc, 0, x)
            b.speedCurve = EditV2.subCurve(sc, x, 1)
        }

        b.id = nid
        b.inSec = src
        b.transitionIn = nil
        b.fadeInSec = nil
        if let k = c.keyframes {
            var ka = EditV2.Keyframes(), kb = EditV2.Keyframes()
            for (prop, keys) in k.present {
                let v = EditV2.keyframeValue(keys, local)
                ka[prop] = keys.filter { $0.t < local - 1e-9 } + [EditV2.Keyframe(t: local, v: v)]
                kb[prop] = [EditV2.Keyframe(t: 0, v: v, ease: keys.last { $0.t <= local + 1e-9 }?.ease)] + keys.filter { $0.t > local + 1e-9 }.map { EditV2.Keyframe(t: $0.t - local, v: $0.v, ease: $0.ease) }
            }
            a.keyframes = ka
            b.keyframes = kb
        }
        if let tr = a.transitionIn, tr.durationSec > EditV2.clipLength(a) / 2 + 1e-9 { return nil }
        if i + 1 < tracks[mi].items.count, let tr = tracks[mi].items[i + 1].videoClip?.transitionIn, tr.durationSec > EditV2.clipLength(b) / 2 + 1e-9 { return nil }
        var p = self
        p.tracks[mi].items.replaceSubrange(i...i, with: [.video(a), .video(b)])
        return (p, nid)
    }

    /// Drops transitions that are on the first main clip or no longer fit their neighbours.
    static func fixTransitions(_ items: [EditV2.Item]) -> [EditV2.Item] {
        items.enumerated().map { i, it in
            guard case .video(var c) = it, let tr = c.transitionIn else { return it }
            let ok = i > 0 && tr.durationSec <= EditV2.clipLength(c) / 2 + 1e-9 && tr.durationSec <= items[i - 1].lengthSec / 2 + 1e-9
            if ok { return it }
            c.transitionIn = nil
            return .video(c)
        }
    }
}

extension EditV2 {
    /// Undo / redo over projects (up to 100 steps), like the v1 EditHistory.
    public struct History: Sendable {
        public static let maxSteps = 100

        public private(set) var current: Project
        private var undoStack: [Project] = []
        private var redoStack: [Project] = []

        public init(_ project: Project) { current = project }

        public var canUndo: Bool { !undoStack.isEmpty }
        public var canRedo: Bool { !redoStack.isEmpty }
        public var undoCount: Int { undoStack.count }

        /// Applies an operation that returns the new project (nil = nothing to do). Returns whether it changed anything.
        @discardableResult
        public mutating func apply(_ op: (Project) -> Project?) -> Bool {
            guard let next = op(current), next != current else { return false }
            push(current)
            current = next
            return true
        }

        private mutating func push(_ p: Project) {
            undoStack.append(p)
            if undoStack.count > History.maxSteps { undoStack.removeFirst(undoStack.count - History.maxSteps) }
            redoStack.removeAll()
        }

        /// A drag: `begin` records one undo step, `update` changes the project without new steps, `end` drops the step
        /// again when the drag ended where it began.
        public mutating func begin() { push(current) }
        public mutating func update(_ p: Project) { current = p }
        public mutating func end() {
            if let last = undoStack.last, last == current { undoStack.removeLast() }
        }

        @discardableResult
        public mutating func undo() -> Bool {
            guard let prev = undoStack.popLast() else { return false }
            redoStack.append(current)
            current = prev
            return true
        }

        @discardableResult
        public mutating func redo() -> Bool {
            guard let next = redoStack.popLast() else { return false }
            undoStack.append(current)
            current = next
            return true
        }

        /// Edit sessions (workstream 3): a change from another device or from Claude becomes the current project without an
        /// undo step of its own, and every local step is rebased onto it (the remote change applied to each snapshot), so
        /// ⌘Z / ⇧⌘Z only ever undo this device's own edits. A step the remote change doesn't fit is dropped with everything
        /// beyond it (older undo steps, further redo steps); steps that would change nothing are dropped too. Undoing someone
        /// else's change is the server's undo (the History list).
        public mutating func adoptRemote(_ next: Project) {
            let base = current
            guard next != base else { return }
            let patch = try? JSONPatch.diff(JSONPatch.encode(base), JSONPatch.encode(next))
            func moved(_ s: Project) -> Project? {
                guard let patch, let doc = try? JSONPatch.apply(JSONPatch.encode(s), patch) else { return nil }
                return try? JSONPatch.decode(Project.self, doc)
            }
            func rebased(_ stack: [Project]) -> [Project] {
                var out: [Project] = []
                var after = next
                for s in stack.reversed() { // nearest step first
                    guard let m = moved(s) else { break }
                    if m != after { out.append(m); after = m }
                }
                return out.reversed()
            }
            undoStack = rebased(undoStack)
            redoStack = rebased(redoStack)
            current = next
        }
    }
}

extension EditV2 {
    /// A take graded with a suite look (workstream 1, `take.look.lut`) starts with that look on its main clip at full strength,
    /// reversible like any look. Only for a starting project built from the take itself (not a saved edit list of its own); the
    /// server does the same when it creates an edit session.
    public static func withTakeLook(_ p: Project, take: Take) -> Project {
        guard let lut = take.look?.lut, !lut.isEmpty, let first = p.mainClips.first, first.look == nil else { return p }
        return p.updating(first.id) { it in
            if case .video(var c) = it { c.look = Look(lut: lut, strength: 1); it = .video(c) }
        } ?? p
    }
}
