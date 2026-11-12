import Foundation

// Edit suite → Layers (plans/layers-edit.md, Phase 1): "Find layers" on a main clip. The owner names up to five things and
// marks each on a frame (tap = a point to keep, ⌥-tap = leave out, drag = a box); one paid run finds them all. Above $1 a
// clip the price is confirmed once more (owner, 2026-11-11). Pure, so the rules are tested here; the Mac draws the frame.

extension EditSuite {
    public static let maxLayerObjects = 5, layersMaxSec = 60.0, layersAskAboveUsd = 1.0
    /// A box counts as up to 9 taps on the server; taps and a box together stay under 10.
    public static let maxPointsPerObject = 10

    public struct LayerDraft: Hashable, Sendable {
        public var name: String
        public var points: [KeepPoint] = []
        public var box: LayerObject.Box?
        public init(name: String) { self.name = name }
        public var marked: Bool { box != nil || points.contains(where: \.keeps) }
    }

    /// The things being marked on one frame of one main clip.
    public struct LayersPick: Hashable, Sendable {
        public var clipId: String
        public var assetId: String
        public var sourceSec: Double
        public var objects: [LayerDraft]
        /// The thing the next tap or box is for.
        public var current = 0
        public var leaveOut = false
        public var confirming = false
        public init(clipId: String, assetId: String, sourceSec: Double, first: String = "Subject") {
            self.clipId = clipId; self.assetId = assetId; self.sourceSec = EditSuite.finiteSeconds(sourceSec)
            objects = [LayerDraft(name: first)]
        }

        public var canAdd: Bool { objects.count < EditSuite.maxLayerObjects }
        public var canRun: Bool {
            !objects.isEmpty && objects.allSatisfy { $0.marked && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        /// Adds a thing to find (named "Layer N" until renamed) and makes it current.
        @discardableResult
        public mutating func add(_ name: String? = nil) -> Bool {
            guard canAdd else { return false }
            objects.append(LayerDraft(name: name ?? "Layer \(objects.count + 1)"))
            current = objects.count - 1
            confirming = false
            return true
        }
        public mutating func remove(_ i: Int) {
            guard objects.indices.contains(i), objects.count > 1 else { return }
            objects.remove(at: i)
            current = min(current, objects.count - 1)
            confirming = false
        }
        public mutating func rename(_ i: Int, _ name: String) {
            guard objects.indices.contains(i) else { return }
            objects[i].name = String(name.prefix(EditV2.maxLayerName))
        }

        /// A tap at (x, y), 0–1 of the frame from the top left, for the current thing: on one of its points removes it,
        /// else adds a point (keep, or leave out). False when nothing changed.
        @discardableResult
        public mutating func tap(x: Double, y: Double, aspect: Double = 1, radius: Double = 0.05) -> Bool {
            guard objects.indices.contains(current), x.isFinite, y.isFinite else { return false }
            let px = min(1, max(0, x)), py = min(1, max(0, y))
            let a = aspect.isFinite && aspect > 0 ? aspect : 1
            let sx = a >= 1 ? a : 1, sy = a >= 1 ? 1 : 1 / a
            var o = objects[current]
            func dist(_ p: KeepPoint) -> Double { let dx = (p.x - px) * sx, dy = (p.y - py) * sy; return (dx * dx + dy * dy).squareRoot() }
            if let i = o.points.indices.min(by: { dist(o.points[$0]) < dist(o.points[$1]) }), dist(o.points[i]) <= radius {
                o.points.remove(at: i)
            } else {
                guard o.points.count + (o.box == nil ? 0 : 9) < EditSuite.maxPointsPerObject else { return false }
                o.points.append(KeepPoint(x: EditV2.r3(px), y: EditV2.r3(py), t: EditV2.r3(sourceSec), keep: leaveOut ? false : nil))
            }
            objects[current] = o
            confirming = false
            return true
        }

        /// A box dragged from (x0, y0) to (x1, y1) for the current thing (replaces its box; a tiny drag is ignored).
        @discardableResult
        public mutating func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Bool {
            guard objects.indices.contains(current), [x0, y0, x1, y1].allSatisfy(\.isFinite) else { return false }
            let a = min(1, max(0, min(x0, x1))), b = min(1, max(0, min(y0, y1))), c = min(1, max(0, max(x0, x1))), d = min(1, max(0, max(y0, y1)))
            guard c - a >= 0.02, d - b >= 0.02, objects[current].points.count <= 1 else { return false }
            objects[current].box = LayerObject.Box(x: EditV2.r3(a), y: EditV2.r3(b), w: EditV2.r3(c - a), h: EditV2.r3(d - b), t: EditV2.r3(sourceSec))
            confirming = false
            return true
        }
        public mutating func clearCurrent() {
            guard objects.indices.contains(current) else { return }
            objects[current].points = []; objects[current].box = nil; confirming = false
        }

        /// The layers job's options.
        public var options: EditorJobOptions {
            var o = EditorJobOptions()
            o.objects = objects.map { LayerObject(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), points: $0.points.isEmpty ? nil : $0.points, box: $0.box) }
            return o
        }
        /// "Her: 2 taps · Dog: box".
        public var summary: String {
            objects.map { o in
                let n = o.points.count
                let marks = [o.box != nil ? "box" : nil, n > 0 ? "\(n) \(n == 1 ? "tap" : "taps")" : nil].compactMap { $0 }
                return "\(o.name): \(marks.isEmpty ? "not marked" : marks.joined(separator: " + "))"
            }.joined(separator: " · ")
        }
    }

    /// A run at this price needs the owner's yes once more (above $1 a clip).
    public static func layersNeedAsk(_ usd: Double?) -> Bool { (usd ?? 0) > layersAskAboveUsd + 1e-9 }

    /// What is wrong with a layers job's objects (the server's checks), or nil.
    public static func layerObjectsProblem(_ objs: [LayerObject], sourceSec: Double?) -> String? {
        if objs.isEmpty || objs.count > maxLayerObjects { return "Mark 1 to \(maxLayerObjects) things" }
        for o in objs {
            if o.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || o.name.count > EditV2.maxLayerName { return "Give each thing a name" }
            let pts = o.points ?? []
            for p in pts {
                if !(0...1).contains(p.x) || !(0...1).contains(p.y) { return "A point is outside the frame" }
                if let t = p.t, !t.isFinite || t < 0 || (sourceSec.map { t > $0 + 0.05 } ?? false) { return "A point is outside the clip" }
            }
            if o.box == nil && !pts.contains(where: \.keeps) { return "Tap \(o.name) or draw a box round it" }
            if let b = o.box, b.x < 0 || b.y < 0 || b.w < 0.01 || b.h < 0.01 || b.x + b.w > 1.0001 || b.y + b.h > 1.0001 { return "The box for \(o.name) must be inside the frame" }
        }
        return nil
    }
}

extension EditV2 {
    /// A finished layers job on the main clip `clipId` (replacing its earlier layers): one matte asset each (`ly<n>`), layers
    /// l1…, the job as their source; pins to layers that are gone come off. Nil when the clip isn't on the main track.
    public static func applyLayerResults(_ p: Project, clipId: String, jobId: String?, found: [LayerResult], sourceAsset: Asset?) -> Project? {
        guard let main = p.tracks.firstIndex(where: { $0.kind == .main }), p.tracks[main].items.contains(where: { $0.id == clipId }), !found.isEmpty else { return nil }
        var q = p
        var layers: [ClipLayer] = []
        for (k, f) in found.prefix(maxLayers).enumerated() {
            let id = q.newId("ly")
            let a = f.asset
            q = q.addingAsset(Asset(id: id, kind: .video, take: a.take, upload: a.take == nil ? a.upload : nil, durationSec: a.durationSec ?? sourceAsset?.durationSec,
                                    width: sourceAsset?.width, height: sourceAsset?.height, hasAudio: false, url: a.url))
            layers.append(ClipLayer(id: "l\(k + 1)", name: String(f.name.prefix(maxLayerName)), matte: id, track: f.track))
        }
        guard var out = q.updating(clipId, { it in
            guard case .video(var v) = it else { return }
            v.layers = layers
            v.layerSource = jobId.map(LayerSource.init(job:))
            it = .video(v)
        }) else { return nil }
        let ids = Set(layers.map(\.id))
        for ti in out.tracks.indices where out.tracks[ti].kind == .text {
            for ii in out.tracks[ti].items.indices {
                guard case .text(var tx) = out.tracks[ti].items[ii], let pin = tx.pin, pin.clip == clipId, !ids.contains(pin.layer) else { continue }
                tx.pin = nil
                out.tracks[ti].items[ii] = .text(tx)
            }
        }
        return out
    }
}
