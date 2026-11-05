import Foundation
#if canImport(CoreGraphics)
import CoreGraphics // CGRect's minX/maxX… live here on Apple platforms
#endif

// The Directed pane's plan (top-down) and side views: fitting the blocking into the drawing, positions at the playhead,
// the camera's view cone, time ticks, and dragging a token or the camera (plans/mcp-bridge.md "Phase 2 · UI").

public enum CameraEase {
    /// `ease` of the key that starts a segment, applied to u ∈ 0…1.
    public static func apply(_ ease: String?, _ u: Double) -> Double {
        let u = min(1, max(0, u))
        switch ease {
        case "in": return u * u
        case "out": return 1 - (1 - u) * (1 - u)
        case "in_out": return u * u * (3 - 2 * u)
        default: return u
        }
    }

    /// "ease in-out", "ease in", "ease out"; nil for linear / none.
    public static func label(_ ease: String?) -> String? {
        switch ease {
        case "in": return "ease in"
        case "out": return "ease out"
        case "in_out": return "ease in-out"
        default: return nil
        }
    }
}

/// The camera at a moment: where it is, where it looks, its lens.
public struct CameraPose: Hashable, Sendable {
    public var position: Vec3
    public var target: Vec3
    public var focalMm: Double
    public init(position: Vec3, target: Vec3, focalMm: Double) {
        self.position = position
        self.target = target
        self.focalMm = focalMm
    }
}

/// A character at a moment.
public struct CharacterPose: Hashable, Sendable {
    public var position: Vec3
    public var facingDeg: Double
    /// The action of the key in effect (the last key at or before t).
    public var action: String?
    public init(position: Vec3, facingDeg: Double, action: String?) {
        self.position = position
        self.facingDeg = facingDeg
        self.action = action
    }

    /// Unit facing direction on the floor: 0° faces -Y, turning counter-clockwise about +Z.
    public var facing: (x: Double, y: Double) {
        let r = facingDeg * .pi / 180
        return (sin(r), -cos(r))
    }
}

public enum CameraMotion {
    public static let defaultFocal = 35.0
    public static let defaultSensor = 36.0

    /// Index of the segment containing t: (i, u) with keys i, i+1; clamps before the first and after the last key.
    static func segment(_ times: [Double], _ t: Double) -> (Int, Int, Double) {
        guard let first = times.first, let last = times.last, times.count > 1 else { return (0, 0, 0) }
        if t <= first { return (0, 0, 0) }
        if t >= last { return (times.count - 1, times.count - 1, 0) }
        var i = 0
        while i + 1 < times.count, times[i + 1] <= t { i += 1 }
        let span = times[i + 1] - times[i]
        return (i, i + 1, span > 0 ? (t - times[i]) / span : 1)
    }

    /// Targets the camera keys left out: the nearest key's own, else 3 m ahead along +Y.
    static func targets(_ keys: [CamKey]) -> [Vec3] {
        keys.indices.map { i in
            if let t = keys[i].target { return t }
            for d in 1..<max(2, keys.count) {
                if i - d >= 0, let t = keys[i - d].target { return t }
                if i + d < keys.count, let t = keys[i + d].target { return t }
            }
            return keys[i].position + Vec3(0, 3, 0)
        }
    }

    public static func camera(_ path: CameraPath?, at t: Double) -> CameraPose? {
        guard let keys = path?.keyframes, !keys.isEmpty else { return nil }
        let tg = targets(keys)
        let (a, b, u) = segment(keys.map(\.t), t)
        let e = CameraEase.apply(keys[a].ease, u)
        let fa = keys[a].focalMm ?? defaultFocal, fb = keys[b].focalMm ?? fa
        return CameraPose(position: Vec3.lerp(keys[a].position, keys[b].position, e), target: Vec3.lerp(tg[a], tg[b], e), focalMm: fa + (fb - fa) * e)
    }

    public static func character(_ track: CameraBlockingTrack, at t: Double) -> CharacterPose? {
        let keys = track.keyframes
        guard !keys.isEmpty else { return nil }
        let (a, b, u) = segment(keys.map(\.t), t)
        let fa = keys[a].facingDeg ?? 0, fb = keys[b].facingDeg ?? fa
        var d = (fb - fa).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        let active = keys.last { $0.t <= t + 1e-9 } ?? keys[0]
        return CharacterPose(position: Vec3.lerp(keys[a].position, keys[b].position, u), facingDeg: fa + d * u, action: active.action)
    }

    /// Horizontal field of view in degrees: 2·atan(sensor/2 / focal).
    public static func horizontalFov(focalMm: Double, sensorMm: Double = defaultSensor) -> Double {
        2 * atan((sensorMm / 2) / max(1, focalMm)) * 180 / .pi
    }
}

/// Which plane a view draws.
public enum PlanProjection: String, Sendable, CaseIterable {
    /// Top-down: X right, +Y up on screen (away from the camera).
    case top
    /// Side: X right, +Z up on screen (heights).
    case side

    public func project(_ v: Vec3) -> CGPoint { self == .top ? CGPoint(x: v.x, y: v.y) : CGPoint(x: v.x, y: v.z) }
}

/// Maps metres to points in a drawing of `size`, fitted to every point of the session (+1 m margin).
public struct PlanGeometry: Equatable, Sendable {
    public var projection: PlanProjection
    /// World bounds (in the projection's plane), margin included.
    public var bounds: CGRect
    public var size: CGSize
    /// Points per metre.
    public var scale: CGFloat
    /// Where bounds.minX / bounds.maxY land (centred).
    public var origin: CGPoint

    public static let margin = 1.0

    public init(session: CameraSession, size: CGSize, projection: PlanProjection = .top) {
        var pts: [Vec3] = []
        if let keys = session.cameraPath?.keyframes {
            pts += keys.map(\.position)
            pts += keys.compactMap(\.target)
        }
        for c in session.blocking?.characters ?? [] {
            pts += c.keyframes.map(\.position)
            if projection == .side {
                let h = session.characters.first { $0.modelId == c.modelId }?.heightM ?? 1.68
                pts += c.keyframes.map { $0.position + Vec3(0, 0, h) }
            }
        }
        self.init(points: pts.map(projection.project), size: size, projection: projection)
    }

    public init(points: [CGPoint], size: CGSize, projection: PlanProjection = .top) {
        self.projection = projection
        self.size = size
        var r: CGRect
        if let f = points.first {
            var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        } else {
            r = CGRect(x: -2, y: -2, width: 4, height: 4)
        }
        let m = CGFloat(Self.margin)
        r = r.insetBy(dx: -m, dy: -m)
        bounds = r
        let sx = size.width / max(r.width, 0.01), sy = size.height / max(r.height, 0.01)
        scale = max(0.0001, min(sx, sy))
        origin = CGPoint(x: (size.width - r.width * scale) / 2, y: (size.height - r.height * scale) / 2)
    }

    /// Metres → points (screen y grows downward).
    public func point(_ v: Vec3) -> CGPoint { point(projection.project(v)) }

    public func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (p.x - bounds.minX) * scale, y: origin.y + (bounds.maxY - p.y) * scale)
    }

    /// Points → metres in the projection's plane.
    public func world(_ p: CGPoint) -> CGPoint {
        CGPoint(x: bounds.minX + (p.x - origin.x) / scale, y: bounds.maxY - (p.y - origin.y) / scale)
    }

    /// Grid lines every `step` metres inside the bounds: (vertical x positions, horizontal y positions) in points.
    public func grid(step: Double = 0.5) -> (xs: [CGFloat], ys: [CGFloat]) {
        let s = CGFloat(step)
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        var x = (bounds.minX / s).rounded(.up) * s
        while x <= bounds.maxX + 1e-9 { xs.append(point(CGPoint(x: x, y: bounds.maxY)).x); x += s }
        var y = (bounds.minY / s).rounded(.up) * s
        while y <= bounds.maxY + 1e-9 { ys.append(point(CGPoint(x: bounds.minX, y: y)).y); y += s }
        return (xs, ys)
    }

    /// The view cone (apex, left edge end, right edge end) in points: horizontal FOV toward the target, `length` metres long
    /// (default: the distance to the target, at least 1.5 m). Top view only (nil in the side view or with no direction).
    public func viewCone(_ pose: CameraPose, sensorMm: Double = CameraMotion.defaultSensor, length: Double? = nil) -> [CGPoint]? {
        guard projection == .top else { return nil }
        let d = pose.target - pose.position
        let len = d.planLength
        guard len > 1e-6 else { return nil }
        let half = CameraMotion.horizontalFov(focalMm: pose.focalMm, sensorMm: sensorMm) / 2 * .pi / 180
        let reach = length ?? max(1.5, len)
        let base = atan2(d.y, d.x)
        func edge(_ a: Double) -> Vec3 { pose.position + Vec3(cos(a) * reach / cos(half), sin(a) * reach / cos(half), 0) }
        return [point(pose.position), point(edge(base + half)), point(edge(base - half))]
    }

    /// "CAM A · 35 mm · 1.5 m" (height above the floor).
    public static func cameraLabel(_ pose: CameraPose, name: String = "CAM A") -> String {
        "\(name) · \(Int(pose.focalMm.rounded())) mm · \(CameraText.metres(pose.position.z))"
    }
}

/// A time tick on a character's path: the key's point and "1.2s".
public struct PathTick: Equatable, Sendable {
    public var point: CGPoint
    public var label: String
}

public enum CameraPathTicks {
    public static func ticks(_ keys: [CharKey], _ g: PlanGeometry) -> [PathTick] {
        keys.map { PathTick(point: g.point($0.position), label: String(format: "%.1fs", $0.t)) }
    }

    public static func ticks(_ keys: [CamKey], _ g: PlanGeometry) -> [PathTick] {
        keys.map { PathTick(point: g.point($0.position), label: String(format: "%.1fs", $0.t)) }
    }

    /// The timeline ruler: whole seconds 0…duration ("0s", "1s"…).
    public static func ruler(duration: Double) -> [(t: Double, label: String)] {
        let n = Int(max(0, duration).rounded(.down))
        return (0...n).map { (Double($0), "\($0)s") }
    }
}

/// What a drag on the plan grabbed.
public enum PlanHandle: Hashable, Sendable {
    case camera
    case character(String)
}

/// Dragging a token or the camera at the playhead: moves the key at that time, or inserts one there.
public enum CameraDrag {
    /// Keys closer than this (seconds) to the playhead are "at" the playhead.
    public static let snap = 1.0 / 48

    /// The nearest handle within `radius` points of `p` at time t (camera first when both are close).
    public static func hit(_ p: CGPoint, session: CameraSession, at t: Double, geometry g: PlanGeometry, radius: CGFloat = 18) -> PlanHandle? {
        var best: (PlanHandle, CGFloat)?
        func consider(_ h: PlanHandle, _ v: Vec3) {
            let q = g.point(v)
            let dx = q.x - p.x, dy = q.y - p.y
            let d: CGFloat = (dx * dx + dy * dy).squareRoot()
            if d <= radius, best == nil || d < best!.1 { best = (h, d) }
        }
        for c in session.blocking?.characters ?? [] {
            if let pose = CameraMotion.character(c, at: t) { consider(.character(c.modelId), pose.position) }
        }
        if let pose = CameraMotion.camera(session.cameraPath, at: t) { consider(.camera, pose.position) }
        return best?.0
    }

    /// The camera path with the camera at `plan` (metres on the floor) at time t. Height, lens and look-at stay.
    public static func moveCamera(_ path: CameraPath, at t: Double, to plan: CGPoint) -> CameraPath {
        var p = path
        if let i = p.keyframes.firstIndex(where: { abs($0.t - t) <= snap }) {
            p.keyframes[i].position.x = plan.x
            p.keyframes[i].position.y = plan.y
            return p
        }
        guard let pose = CameraMotion.camera(path, at: t) else {
            p.keyframes = [CamKey(t: t, position: Vec3(plan.x, plan.y, 1.5))]
            return p
        }
        let prev = path.keyframes.last { $0.t <= t }
        let k = CamKey(t: t, position: Vec3(plan.x, plan.y, pose.position.z), target: pose.target, focalMm: pose.focalMm, rollDeg: prev?.rollDeg, ease: prev?.ease)
        p.keyframes.append(k)
        p.keyframes.sort { $0.t < $1.t }
        return p
    }

    /// The character's track with them at `plan` at time t. Facing stays; the action belongs to the existing key only.
    public static func moveCharacter(_ track: CameraBlockingTrack, at t: Double, to plan: CGPoint) -> CameraBlockingTrack {
        var tr = track
        if let i = tr.keyframes.firstIndex(where: { abs($0.t - t) <= snap }) {
            tr.keyframes[i].position.x = plan.x
            tr.keyframes[i].position.y = plan.y
            return tr
        }
        let pose = CameraMotion.character(track, at: t)
        tr.keyframes.append(CharKey(t: t, position: Vec3(plan.x, plan.y, pose?.position.z ?? 0), facingDeg: pose?.facingDeg))
        tr.keyframes.sort { $0.t < $1.t }
        return tr
    }

    /// The PUT …/path body after dragging `handle` to `plan` (only the part that changed). Times clamp to 0…duration.
    public static func update(_ session: CameraSession, handle: PlanHandle, at t: Double, to plan: CGPoint) -> CameraPathUpdate? {
        let t = min(max(0, t), session.durationSec)
        switch handle {
        case .camera:
            let path = session.cameraPath ?? CameraPath(keyframes: [])
            return CameraPathUpdate(camera: moveCamera(path, at: t, to: plan))
        case .character(let id):
            guard var tracks = session.blocking?.characters, let i = tracks.firstIndex(where: { $0.modelId == id }) else { return nil }
            tracks[i] = moveCharacter(tracks[i], at: t, to: plan)
            return CameraPathUpdate(characters: tracks)
        }
    }

    /// The session as it looks after the update (shown at once while the PUT is in flight).
    public static func applying(_ u: CameraPathUpdate, to s: CameraSession) -> CameraSession {
        var s = s
        if let c = u.camera { s.cameraPath = c }
        if let ch = u.characters { s.blocking = CameraBlocking(characters: ch) }
        return s
    }
}
