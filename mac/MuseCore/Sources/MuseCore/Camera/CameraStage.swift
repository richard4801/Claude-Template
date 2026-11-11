import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Camera stage viewer (owner, 2026-11-11): the greybox guide plays in the page, the paths are drawn over the Camera view,
// and a light 3D preview orbits the scene. The pure parts live here: projecting the paths through the shot camera,
// keeping the timeline playhead and the video player in step, and reading the set blocks Blender exports (set.json).

// MARK: Projection through the shot camera

/// The shot camera at one moment as a pinhole, matching Blender's render (sensor fit AUTO: the sensor spans the frame's
/// longer side; no lens shift). Screen points are normalised to the frame: x 0…1 left→right, y 0…1 top→bottom.
public struct ShotCameraProjection: Equatable, Sendable {
    public var position: Vec3
    /// Unit axes: right, up (screen), forward (into the frame).
    public var right: Vec3
    public var up: Vec3
    public var forward: Vec3
    /// Focal length in units of the frame's longer side.
    public var focal: Double
    /// Frame width / height.
    public var aspect: Double
    /// Nearer than this (metres, along the view) is not drawn.
    public static let near = 0.05

    /// nil when the camera has no direction (target on top of it).
    public init?(_ pose: CameraPose, aspect: Double, sensorMm: Double = CameraMotion.defaultSensor) {
        let d = pose.target - pose.position
        guard d.length > 1e-9, aspect > 0 else { return nil }
        let f = d * (1 / d.length)
        // Right = forward × world up; straight down/up falls back to +X as right (no roll in the poses).
        var r = Vec3(f.y, -f.x, 0)
        if r.length < 1e-6 { r = Vec3(1, 0, 0) } else { r = r * (1 / r.length) }
        let u = Vec3(r.y * f.z - r.z * f.y, r.z * f.x - r.x * f.z, r.x * f.y - r.y * f.x)
        position = pose.position
        right = r
        up = u
        forward = f
        focal = max(1, pose.focalMm) / max(1, sensorMm)
        self.aspect = aspect
    }

    static func dot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    /// Camera-space coordinates: (right, up, depth).
    public func cameraSpace(_ p: Vec3) -> Vec3 {
        let d = p - position
        return Vec3(Self.dot(d, right), Self.dot(d, up), Self.dot(d, forward))
    }

    /// The point on the frame (normalised), or nil when it is behind the camera. Points outside 0…1 are off-frame.
    public func project(_ p: Vec3) -> CGPoint? {
        let c = cameraSpace(p)
        guard c.z > Self.near else { return nil }
        return screen(c)
    }

    func screen(_ c: Vec3) -> CGPoint {
        // Pixels over the longer side: x_px = W/2 + f·L·X/Z, y_px = H/2 − f·L·Y/Z; normalised by W and H.
        let longW = aspect >= 1 ? 1.0 : 1 / aspect // L / W
        let longH = aspect >= 1 ? aspect : 1.0     // L / H
        return CGPoint(x: 0.5 + focal * longW * c.x / c.z, y: 0.5 - focal * longH * c.y / c.z)
    }

    /// A polyline through the camera: split into runs where it passes behind the camera (clipped at the near plane).
    public func project(polyline pts: [Vec3]) -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var cur: [CGPoint] = []
        var prev: Vec3?
        for p in pts {
            let c = cameraSpace(p)
            if let a = prev {
                let aIn = a.z > Self.near, bIn = c.z > Self.near
                if aIn != bIn {
                    // Where the segment crosses the near plane.
                    let u = (Self.near + 1e-6 - a.z) / (c.z - a.z)
                    let x = Vec3.lerp(a, c, u)
                    if aIn {
                        cur.append(screen(Vec3(x.x, x.y, max(x.z, Self.near + 1e-6))))
                        if cur.count > 1 { runs.append(cur) }
                        cur = []
                    } else {
                        cur = [screen(Vec3(x.x, x.y, max(x.z, Self.near + 1e-6)))]
                    }
                }
            }
            if c.z > Self.near { cur.append(screen(c)) }
            prev = c
        }
        if cur.count > 1 { runs.append(cur) }
        return runs
    }
}

public enum CameraStageMath {
    /// "9:16" → 0.5625; unknown → 9:16.
    public static func aspect(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return 9.0 / 16 }
        return parts[0] / parts[1]
    }

    /// Sample times 0…duration: every key time plus `perSecond` steps, sorted, unique.
    public static func sampleTimes(duration: Double, keys: [Double], perSecond: Double = 12) -> [Double] {
        let d = max(0, duration)
        let n = max(1, Int((d * perSecond).rounded(.up)))
        var ts = (0...n).map { d * Double($0) / Double(n) }
        ts += keys.filter { $0 >= 0 && $0 <= d }
        return Array(Set(ts)).sorted()
    }

    /// A character's floor path over the whole shot (positions sampled from the interpolated keys).
    public static func characterPath(_ track: CameraBlockingTrack, duration: Double) -> [Vec3] {
        let last = max(duration, track.keyframes.last?.t ?? 0)
        return sampleTimes(duration: last, keys: track.keyframes.map(\.t)).compactMap { CameraMotion.character(track, at: $0)?.position }
    }

    /// The camera's path over the whole shot.
    public static func cameraPath(_ path: CameraPath?, duration: Double) -> [Vec3] {
        guard let keys = path?.keyframes, !keys.isEmpty else { return [] }
        let last = max(duration, keys.last?.t ?? 0)
        return sampleTimes(duration: last, keys: keys.map(\.t)).compactMap { CameraMotion.camera(path, at: $0)?.position }
    }

    /// What the Camera view draws over the video: each character's path on the floor and their position now, seen from the
    /// shot camera at time t; the camera's own path ahead of it. Normalised frame coordinates.
    public static func overlay(_ s: CameraSession, at t: Double) -> CameraOverlay? {
        guard let pose = CameraMotion.camera(s.cameraPath, at: t),
              let cam = ShotCameraProjection(pose, aspect: aspect(s.aspect), sensorMm: s.cameraPath?.sensorMm ?? CameraMotion.defaultSensor)
        else { return nil }
        var chars: [CameraOverlay.Character] = []
        for (i, track) in (s.blocking?.characters ?? []).enumerated() where !track.keyframes.isEmpty {
            let index = s.characters.firstIndex { $0.modelId == track.modelId } ?? i
            let now = CameraMotion.character(track, at: t).flatMap { cam.project($0.position) }
            chars.append(.init(modelId: track.modelId, castIndex: index, path: cam.project(polyline: characterPath(track, duration: s.durationSec)), now: now))
        }
        let ahead = cameraPath(s.cameraPath, duration: s.durationSec)
        return CameraOverlay(characters: chars, cameraPath: cam.project(polyline: ahead))
    }
}

/// Paths over the Camera view, in normalised frame coordinates.
public struct CameraOverlay: Equatable, Sendable {
    public struct Character: Equatable, Sendable {
        public var modelId: String
        public var castIndex: Int
        public var path: [[CGPoint]]
        /// Where they stand at the playhead (nil: behind the camera).
        public var now: CGPoint?
    }
    public var characters: [Character]
    public var cameraPath: [[CGPoint]]
}

// MARK: Timeline ↔ player

/// Keeps the timeline playhead and the guide video in step. The video's time IS the shot time (Blender renders frame 1 at
/// 0 s, `durationSec` long); the playhead drives the video (seek) unless the change came from the video itself.
public enum StagePlayback {
    /// Within this the player is "already there" (half a frame).
    public static func tolerance(fps: Double) -> Double { 0.5 / max(1, fps) }

    /// A playhead change should seek the player when it is more than half a frame from where the player is.
    public static func needsSeek(playerTime: Double, playhead: Double, fps: Double) -> Bool {
        abs(playerTime - playhead) > tolerance(fps: fps)
    }

    /// The playhead for a time the player reports: clamped to the shot (a video a frame longer doesn't run past END).
    public static func playhead(fromPlayer t: Double, duration: Double) -> Double {
        guard t.isFinite else { return 0 }
        return min(max(0, t), max(0, duration))
    }

    /// Where Play starts: from the playhead, or from 0 when it sits at the end.
    public static func startTime(playhead: Double, duration: Double, fps: Double) -> Double {
        playhead >= duration - tolerance(fps: fps) ? 0 : max(0, playhead)
    }

    /// A clock step with no video (the plan alone plays): the next playhead and whether it keeps playing.
    public static func advance(_ playhead: Double, by dt: Double, duration: Double, loop: Bool) -> (time: Double, playing: Bool) {
        let d = max(0, duration)
        guard d > 0 else { return (0, false) }
        let next = playhead + max(0, dt)
        if next < d { return (next, true) }
        if loop { return (next.truncatingRemainder(dividingBy: d), true) }
        return (d, false)
    }

    /// The playhead snapped to a frame (the keyboard's ← → step by one frame).
    public static func step(_ playhead: Double, frames: Int, fps: Double, duration: Double) -> Double {
        let f = max(1, fps)
        let frame = (playhead * f).rounded() + Double(frames)
        return min(max(0, frame / f), max(0, duration))
    }

    /// "1.2 / 6.0 s"
    public static func timeLabel(_ t: Double, duration: Double) -> String {
        String(format: "%.1f / %.1f s", max(0, t), max(0, duration))
    }
}

// MARK: Set blocks (set.json)

/// The set as Blender exported it with the greybox (`set.json`): one box (or cylinder, sphere, plane) per object.
/// Blender world, metres, Z up; position = bottom centre (a plane's centre).
public struct CameraSetFile: Codable, Equatable, Sendable {
    public struct Object: Codable, Equatable, Sendable {
        public var name: String
        public var shape: String
        public var size: Vec3
        public var position: Vec3
        public var rotationDeg: Vec3?
        public init(name: String, shape: String, size: Vec3, position: Vec3, rotationDeg: Vec3? = nil) {
            self.name = name
            self.shape = shape
            self.size = size
            self.position = position
            self.rotationDeg = rotationDeg
        }
    }
    public var version: Int
    public var objects: [Object]
    public init(version: Int = 1, objects: [Object]) {
        self.version = version
        self.objects = objects
    }

    /// Parses set.json; drops objects with a bad size and keeps at most 400.
    public static func parse(_ data: Data) -> CameraSetFile? {
        guard var f = try? JSONDecoder().decode(CameraSetFile.self, from: data) else { return nil }
        f.objects = Array(f.objects.filter { o in
            [o.size.x, o.size.y, o.size.z, o.position.x, o.position.y, o.position.z].allSatisfy(\.isFinite)
                && o.size.x >= 0 && o.size.y >= 0 && o.size.z >= 0 && max(o.size.x, o.size.y, o.size.z) > 0 && max(o.size.x, o.size.y, o.size.z) <= 200
        }.prefix(400))
        return f
    }

    /// The newest ready set.json of a session.
    public static func asset(_ s: CameraSession) -> CameraAsset? {
        s.assets.filter { $0.kind == "set_json" && $0.state == "ready" && $0.url != nil }.max { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
    }
}

/// The 3D preview's starting view: looking at the middle of everything from the front-left, above.
public struct OrbitFraming: Equatable, Sendable {
    public var target: Vec3
    public var eye: Vec3

    public static func of(_ s: CameraSession, set: CameraSetFile? = nil) -> OrbitFraming {
        var pts: [Vec3] = []
        if let keys = s.cameraPath?.keyframes { pts += keys.map(\.position) + keys.compactMap(\.target) }
        for c in s.blocking?.characters ?? [] { pts += c.keyframes.map(\.position) }
        for o in set?.objects ?? [] where max(o.size.x, o.size.y) < 20 { pts.append(o.position) } // not the 40 m floor
        guard let f = pts.first else { return OrbitFraming(target: Vec3(0, 0, 0.9), eye: Vec3(-4, -6, 4)) }
        var lo = f, hi = f
        for p in pts {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        let c = Vec3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0.9)
        let r = max(2.5, (hi - lo).length / 2)
        // From -Y (the usual camera side), 35° to the left, 30° up, far enough to fit a ~2r wide scene in a 40° view.
        let dist = r / tan(20 * Double.pi / 180) * 1.1
        let yaw = -35 * Double.pi / 180, pitch = 30 * Double.pi / 180
        let eye = c + Vec3(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch)) * dist
        return OrbitFraming(target: c, eye: eye)
    }
}
