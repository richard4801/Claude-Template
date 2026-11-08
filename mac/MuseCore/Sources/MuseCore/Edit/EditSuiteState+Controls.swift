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
        if let keys = v.keyframes?[prop], !keys.isEmpty { return addKeyframe(prop, value: value, ease: keys.first?.ease ?? .easeInOut) }
        return changeVisual { vv in
            var tf = vv.transform ?? E.Transform()
            switch prop {
            case .x: tf.x = E.r6(value)
            case .y: tf.y = E.r6(value)
            case .scale: tf.scale = E.r6(min(10, max(0.05, value)))
            case .rotation: tf.rotation = E.r6(min(3600, max(-3600, value)))
            case .opacity: vv.opacity = E.r6(min(1, max(0, value))); return
            case .volume: return
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
                }
                if prop != .opacity && prop != .volume { v.transform = tf }
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
