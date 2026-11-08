import Foundation

// Edit suite (workstream 3): Remove background → "Pick what to keep" (tap to keep, plans/api.md "KeepPoint"). The owner taps
// what to keep on a frame of the clip's source (and, switched to "Leave out", what to leave out); the points go to the matte job
// with that frame's source time. Pure, so the tap rules are tested here; the Mac draws the frame and the dots.

extension EditSuite {
    /// At most this many points per job (the server's limit).
    public static let maxKeepPoints = 10

    /// The points picked on one frame of one clip.
    public struct KeepPick: Hashable, Sendable {
        public var clipId: String
        /// The clip's own asset (the matte lines up with it).
        public var assetId: String
        /// The frame's time in the source, seconds.
        public var sourceSec: Double
        public var points: [KeepPoint] = []
        /// The next tap leaves out instead of keeping.
        public var leaveOut = false
        /// The price was shown and the owner is asked to confirm.
        public var confirming = false
        public init(clipId: String, assetId: String, sourceSec: Double) {
            self.clipId = clipId; self.assetId = assetId; self.sourceSec = EditSuite.finiteSeconds(sourceSec)
        }

        public var keepCount: Int { points.filter(\.keeps).count }
        public var leaveOutCount: Int { points.count - keepCount }
        /// At least one point to keep.
        public var canRun: Bool { keepCount > 0 }

        /// A tap at (x, y), 0–1 of the frame from the top left. A tap on a point (within `radius` of the frame's shorter side)
        /// removes it; otherwise a point is added (keep, or leave out), up to `maxKeepPoints`. `aspect` is width / height.
        /// Returns false when nothing changed.
        @discardableResult
        public mutating func tap(x: Double, y: Double, aspect: Double = 1, radius: Double = 0.05) -> Bool {
            guard x.isFinite, y.isFinite else { return false }
            let px = min(1, max(0, x)), py = min(1, max(0, y))
            let a = aspect.isFinite && aspect > 0 ? aspect : 1
            // Distances in units of the shorter side, so the hit area is round on any frame shape.
            let sx = a >= 1 ? a : 1, sy = a >= 1 ? 1 : 1 / a
            if let i = points.indices.min(by: { dist(points[$0], px, py, sx, sy) < dist(points[$1], px, py, sx, sy) }),
               dist(points[i], px, py, sx, sy) <= radius {
                points.remove(at: i)
                confirming = false
                return true
            }
            guard points.count < EditSuite.maxKeepPoints else { return false }
            points.append(KeepPoint(x: EditV2.r3(px), y: EditV2.r3(py), t: EditV2.r3(sourceSec), keep: leaveOut ? false : nil))
            confirming = false
            return true
        }

        private func dist(_ p: KeepPoint, _ x: Double, _ y: Double, _ sx: Double, _ sy: Double) -> Double {
            let dx = (p.x - x) * sx, dy = (p.y - y) * sy
            return (dx * dx + dy * dy).squareRoot()
        }

        public mutating func clear() { points = []; confirming = false }

        /// The matte job's options.
        public var options: EditorJobOptions { EditorJobOptions(points: points) }

        /// "Tap what to keep" · "2 kept · 1 left out".
        public var summary: String {
            if points.isEmpty { return "Tap what to keep" }
            var parts = ["\(keepCount) kept"]
            if leaveOutCount > 0 { parts.append("\(leaveOutCount) left out") }
            return parts.joined(separator: " · ")
        }
    }

    /// What is wrong with a job's keep points (the server's checks), or nil: 1–10 points, 0–1 of the frame, `t` inside the
    /// source, at least one kept.
    public static func keepPointsProblem(_ points: [KeepPoint], sourceSec: Double?) -> String? {
        if points.isEmpty || points.count > maxKeepPoints { return "Tap 1 to \(maxKeepPoints) points" }
        for p in points {
            if !(0...1).contains(p.x) || !(0...1).contains(p.y) { return "A point is outside the frame" }
            if let t = p.t, !t.isFinite || t < 0 || (sourceSec.map { t > $0 + 0.05 } ?? false) { return "A point is outside the clip" }
        }
        if !points.contains(where: \.keeps) { return "Tap at least one thing to keep" }
        return nil
    }
}

extension EditV2 {
    /// The source second a video segment shows at timeline second `t` (through its constant-speed pieces), clamped to the segment.
    public static func sourceTime(_ seg: VideoSegment, at t: Double) -> Double {
        var local = max(0, min(seg.timelineLength, t - seg.timelineStart))
        if seg.pieces.isEmpty {
            let len = seg.timelineLength
            return len > 0 ? seg.sourceStart + (seg.sourceEnd - seg.sourceStart) * local / len : seg.sourceStart
        }
        for pc in seg.pieces {
            if local <= pc.length || pc == seg.pieces.last! { return min(pc.outSec, pc.inSec + local * pc.speed) }
            local -= pc.length
        }
        return seg.sourceEnd
    }
}
