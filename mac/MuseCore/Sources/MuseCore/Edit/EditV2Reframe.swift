import Foundation

// Auto reframe that follows faces (XL, owner-approved 2026-11-09; on the device: Apple Vision on the Mac, ML Kit on
// Android). Ordinary keyframes, no contract change. The same steps as Android's core Reframe.kt (WS8), so both feel
// alike: x only (the cover fit stays), EMA a = 0.4, a 0.04 dead zone, RDP 0.01 (× 1.5 until ≤ 40 keys), easeInOut keys
// rounded to ms / 1e-4, and a still picture as a plain transform.x.

extension EditV2 {
    /// The followed face at `t` seconds from the clip's start on the timeline: `x` its centre across the source picture
    /// (0 = left), nil when no face was found there (the position holds).
    public struct FaceSample: Hashable, Sendable {
        public var t: Double
        public var x: Double?
        public init(t: Double, x: Double?) { self.t = t; self.x = x }
    }

    /// What following a face does to a clip: keys on x, or one still position.
    public enum FaceFollow: Hashable, Sendable {
        case keys([Keyframe])
        case still(Double)
    }

    public static let reframeEma = 0.4, reframeDeadZone = 0.04, reframeTolerance = 0.01, reframeMaxKeys = 40

    /// The clip's x so the face is centred without showing an edge: nil when the picture doesn't overflow the canvas
    /// sideways, or no face was found.
    public static func followFace(_ c: VideoClip, asset: Asset, canvasWidth cw: Double, canvasHeight ch: Double, samples: [FaceSample]) -> FaceFollow? {
        guard let w = asset.width, let h = asset.height, cw > 0, ch > 0, w > 0, h > 0 else { return nil }
        let cover = max((Double(w) / Double(h)) / (cw / ch), 1) * (c.transform?.scale ?? 1)
        guard cover > 1.0001 else { return nil }
        let lim = (cover - 1) / 2
        let pts = samples.filter { $0.t.isFinite }.sorted { $0.t < $1.t }
        guard let firstFace = pts.first(where: { $0.x != nil })?.x else { return nil }
        // Raw centres; a frame without a face holds the last one (before the first face: the first face).
        var last = min(1, max(0, firstFace))
        let raw: [(t: Double, v: Double)] = pts.map { p in
            if let x = p.x { last = min(1, max(0, x)) }
            return (p.t, min(0.5 + lim, max(0.5 - lim, 0.5 + (0.5 - last) * cover)))
        }
        // EMA, then the dead zone: the shown x moves only once the smoothed x leaves the band, trailing at its edge.
        var s = raw[0].v, shown = raw[0].v
        let path: [(t: Double, v: Double)] = raw.map { p in
            s += reframeEma * (p.v - s)
            if s > shown + reframeDeadZone { shown = s - reframeDeadZone } else if s < shown - reframeDeadZone { shown = s + reframeDeadZone }
            return (p.t, shown)
        }
        var tol = reframeTolerance
        var idx = rdp(path, tol)
        while idx.count > reframeMaxKeys { tol *= 1.5; idx = rdp(path, tol) }
        let keys = idx.map { Keyframe(t: (path[$0].t * 1000).rounded() / 1000, v: (path[$0].v * 1e4).rounded() / 1e4, ease: .easeInOut) }
        if keys.count <= 1 || keys.allSatisfy({ $0.v == keys[0].v }) { return .still(keys.first?.v ?? 0.5) }
        return .keys(keys)
    }

    /// Ramer–Douglas–Peucker on a path: the indexes kept (first and last always).
    static func rdp(_ pts: [(t: Double, v: Double)], _ tol: Double) -> [Int] {
        guard pts.count > 2 else { return Array(pts.indices) }
        var keep = Set([0, pts.count - 1])
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var worst = -1.0, at = a
            for i in (a + 1)..<b {
                let f = (pts[i].t - pts[a].t) / max(1e-9, pts[b].t - pts[a].t)
                let d = abs(pts[i].v - (pts[a].v + (pts[b].v - pts[a].v) * f))
                if d > worst { worst = d; at = i }
            }
            if worst > tol { keep.insert(at); stack.append((a, at)); stack.append((at, b)) }
        }
        return keep.sorted()
    }
}

extension EditSuiteState {
    /// Auto reframe: the selected clip follows the face in `samples`: x keys (replacing its x keys), or a still x with
    /// the x keys dropped. Refused when no face was found or the picture doesn't overflow sideways.
    @discardableResult
    public mutating func followFaces(_ samples: [E.FaceSample]) -> Bool {
        guard let c = selectedVideo, let a = project.asset(c.asset) else { return false }
        guard samples.contains(where: { $0.x != nil }) else { refuse("No face found in this clip"); return false }
        guard let f = E.followFace(c, asset: a, canvasWidth: Double(project.canvas.width), canvasHeight: Double(project.canvas.height), samples: samples) else {
            refuse("The picture already fits the frame · zoom in or change the shape to give it room to move")
            return false
        }
        return changeVisual { v in
            var k = v.keyframes ?? E.Keyframes()
            switch f {
            case .keys(let keys): k.x = keys
            case .still(let x):
                k.x = nil
                var tf = v.transform ?? E.Transform()
                tf.x = x
                v.transform = tf
            }
            v.keyframes = k.isEmpty ? nil : k
        }
    }
}
