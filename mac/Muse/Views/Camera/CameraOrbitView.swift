import MuseCore
import SceneKit
import SwiftUI

// The 3D preview (owner, 2026-11-11): a light SceneKit scene built from the session itself — floor, the set blocks Blender
// exported with the greybox (set.json; without one, the floor alone), a capsule per character on her path, the shot
// camera as a frustum on its path. Drag to orbit, scroll to zoom, double-click to reset; "Shot camera" looks through the
// camera. It follows the playhead like the other views. The scene is built once per revision; the playhead only moves
// nodes. Everything sits under one node turned from Blender's Z-up world into SceneKit's Y-up.

struct CameraOrbitView: View {
    @Environment(\.theme) private var t
    var session: CameraSession
    var playhead: Double
    @State private var throughCamera = false
    @State private var resetToken = 0
    @State private var set: CameraSetFile?
    @State private var setId: String?

    var body: some View {
        let setAsset = CameraSetFile.asset(session)
        ZStack(alignment: .topLeading) {
            OrbitSceneView(session: session, playhead: playhead, set: set, setId: setId, throughCamera: throughCamera, resetToken: resetToken,
                           background: NSColor(t.surface), cast: (0..<4).map { NSColor(CastStyle.color($0, t)) }, ink: NSColor(t.ink), accent: NSColor(t.accent))
            HStack(spacing: 8) {
                Chip("Shot camera", on: throughCamera) { throughCamera.toggle() }
                    .help("Look through the shot camera")
                MButton("Reset view", size: .small) {
                    throughCamera = false
                    resetToken += 1
                }
                .help("Back to the starting view (or double-click the scene)")
            }
            .padding(10)
            VStack {
                Spacer()
                HStack {
                    Text(note(setAsset)).font(t.body(11.5)).foregroundStyle(t.muted)
                    Spacer()
                }
            }
            .padding(10)
            .allowsHitTesting(false)
        }
        .task(id: setAsset?.id) { await loadSet(setAsset) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("3D preview at \(CameraTimeline.playheadLabel(playhead))")
    }

    private func note(_ a: CameraAsset?) -> String {
        if throughCamera { return "Through the shot camera · Reset view to orbit" }
        let base = "Drag to orbit · scroll to zoom · double-click to reset"
        return a == nil ? base + " · set blocks arrive with the next greybox render" : base
    }

    private func loadSet(_ a: CameraAsset?) async {
        guard let a, let s = a.url, let url = URL(string: s) else {
            set = nil
            setId = nil
            return
        }
        if setId == a.id { return }
        // Off the main thread; the disk cache keeps it.
        guard let data = try? await ImageDataLoader.shared.data(for: url), !Task.isCancelled else { return }
        let parsed = await Task.detached(priority: .userInitiated) { CameraSetFile.parse(data) }.value
        set = parsed
        setId = a.id
    }
}

private struct OrbitSceneView: NSViewRepresentable {
    var session: CameraSession
    var playhead: Double
    var set: CameraSetFile?
    var setId: String?
    var throughCamera: Bool
    var resetToken: Int
    var background: NSColor
    var cast: [NSColor]
    var ink: NSColor
    var accent: NSColor

    func makeCoordinator() -> OrbitScene { OrbitScene() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = context.coordinator.scene
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = false
        v.preferredFramesPerSecond = 60
        let dbl = NSClickGestureRecognizer(target: context.coordinator, action: #selector(OrbitScene.doubleClicked(_:)))
        dbl.numberOfClicksRequired = 2
        v.addGestureRecognizer(dbl)
        context.coordinator.view = v
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        v.backgroundColor = background
        c.style = .init(cast: cast, ink: ink, accent: accent)
        c.build(session, set: set, setId: setId)
        c.pose(session, at: playhead)
        if c.resetToken != resetToken {
            c.resetToken = resetToken
            c.resetView()
        }
        c.look(throughCamera: throughCamera)
    }
}

@MainActor
final class OrbitScene: NSObject {
    struct Style {
        var cast: [NSColor] = [.systemRed, .labelColor, .systemGreen, .secondaryLabelColor]
        var ink: NSColor = .labelColor
        var accent: NSColor = .systemRed
    }

    let scene = SCNScene()
    weak var view: SCNView?
    var style = Style()
    var resetToken = 0
    private var key: String?
    /// Blender world (Z up) → SceneKit (Y up).
    private let world = SCNNode()
    private let content = SCNNode()
    private let orbitCamera = SCNNode()
    private let shotCamera = SCNNode()
    private var characters: [String: SCNNode] = [:]
    private var framing = OrbitFraming(target: Vec3(0, 0, 0.9), eye: Vec3(-4, -6, 4))
    private var through = false
    private var aspect = 9.0 / 16
    private var sensor = CameraMotion.defaultSensor
    private var frustumFov = -1.0

    override init() {
        super.init()
        world.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(world)
        world.addChildNode(content)
        let cam = SCNCamera()
        cam.fieldOfView = 40
        cam.zNear = 0.05
        cam.zFar = 400
        orbitCamera.camera = cam
        scene.rootNode.addChildNode(orbitCamera)
        let shot = SCNCamera()
        shot.zNear = 0.05
        shot.zFar = 400
        shotCamera.camera = shot
        world.addChildNode(shotCamera)
        // Soft, even light: a key from above-front and ambient fill, like Blender's flat greybox.
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 750
        keyLight.eulerAngles = SCNVector3(-CGFloat.pi / 3, -CGFloat.pi / 6, 0)
        scene.rootNode.addChildNode(keyLight)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 420
        scene.rootNode.addChildNode(amb)
    }

    // MARK: Building (once per revision / set file / theme)

    func build(_ s: CameraSession, set: CameraSetFile?, setId: String?) {
        let k = "\(s.id)#\(s.revision)#\(s.updatedAt)#\(setId ?? "-")#\(style.ink.description)#\(style.accent.description)"
        guard k != key else { return }
        let firstBuild = key == nil || key?.hasPrefix("\(s.id)#") == false
        key = k
        content.childNodes.forEach { $0.removeFromParentNode() }
        characters = [:]
        aspect = CameraStageMath.aspect(s.aspect)
        sensor = s.cameraPath?.sensorMm ?? CameraMotion.defaultSensor

        content.addChildNode(floor())
        for o in set?.objects ?? [] where !(o.name == "MUSE_floor") { content.addChildNode(block(o)) }

        for (i, track) in (s.blocking?.characters ?? []).enumerated() where !track.keyframes.isEmpty {
            let idx = s.characters.firstIndex { $0.modelId == track.modelId } ?? i
            let color = style.cast[idx % max(1, style.cast.count)]
            let h = s.characters.first { $0.modelId == track.modelId }?.heightM ?? 1.68
            content.addChildNode(line(CameraStageMath.characterPath(track, duration: s.durationSec).map { $0 + Vec3(0, 0, 0.01) }, color: color))
            let n = figure(height: h, color: color)
            content.addChildNode(n)
            characters[track.modelId] = n
        }
        let camPath = CameraStageMath.cameraPath(s.cameraPath, duration: s.durationSec)
        if camPath.count > 1 { content.addChildNode(line(camPath, color: style.ink)) }
        shotCamera.childNodes.forEach { $0.removeFromParentNode() }
        frustumFov = -1
        shotCamera.isHidden = s.cameraPath?.keyframes.isEmpty ?? true

        framing = OrbitFraming.of(s, set: set)
        if firstBuild { resetView() }
    }

    private func floor() -> SCNNode {
        let n = SCNNode()
        let plane = SCNBox(width: 40, height: 40, length: 0.002, chamferRadius: 0)
        plane.firstMaterial = mat(NSColor(white: 0.78, alpha: 1))
        let p = SCNNode(geometry: plane)
        p.position = SCNVector3(0, 0, -0.001)
        n.addChildNode(p)
        // 1 m grid over ±10 m.
        var segs: [(Vec3, Vec3)] = []
        for i in -10...10 {
            segs.append((Vec3(Double(i), -10, 0.002), Vec3(Double(i), 10, 0.002)))
            segs.append((Vec3(-10, Double(i), 0.002), Vec3(10, Double(i), 0.002)))
        }
        n.addChildNode(lines(segs, color: NSColor(white: 0.62, alpha: 1)))
        return n
    }

    private func block(_ o: CameraSetFile.Object) -> SCNNode {
        let sx = CGFloat(o.size.x), sy = CGFloat(o.size.y), sz = CGFloat(o.size.z)
        let outer = SCNNode()
        outer.position = SCNVector3(o.position.x, o.position.y, o.position.z)
        let r = o.rotationDeg ?? Vec3(0, 0, 0)
        outer.eulerAngles = SCNVector3(r.x * .pi / 180, r.y * .pi / 180, r.z * .pi / 180)
        let g: SCNGeometry
        let inner = SCNNode()
        switch o.shape {
        case "cylinder":
            g = SCNCylinder(radius: max(sx, sy) / 2, height: sz)
            inner.eulerAngles.x = .pi / 2
            inner.position = SCNVector3(0, 0, sz / 2)
        case "sphere":
            g = SCNSphere(radius: 0.5)
            inner.scale = SCNVector3(sx, sy, sz)
            inner.position = SCNVector3(0, 0, sz / 2)
        case "plane":
            g = SCNBox(width: sx, height: sy, length: max(0.004, sz), chamferRadius: 0)
        default:
            g = SCNBox(width: sx, height: sy, length: sz, chamferRadius: 0)
            inner.position = SCNVector3(0, 0, sz / 2)
        }
        g.firstMaterial = mat(NSColor(white: 0.9, alpha: 1))
        inner.geometry = g
        outer.addChildNode(inner)
        return outer
    }

    private func figure(height h: Double, color: NSColor) -> SCNNode {
        let n = SCNNode()
        let radius = CGFloat(0.13 * h)
        let body = SCNNode(geometry: SCNCapsule(capRadius: radius, height: CGFloat(h)))
        body.geometry?.firstMaterial = mat(color)
        body.eulerAngles.x = .pi / 2 // capsule axis Y → Blender Z
        body.position = SCNVector3(0, 0, h / 2)
        n.addChildNode(body)
        // A nose toward facing 0° (-Y) shows which way she looks.
        let nose = SCNNode(geometry: SCNBox(width: radius * 0.6, height: radius * 0.9, length: radius * 0.5, chamferRadius: 0))
        nose.geometry?.firstMaterial = mat(style.ink)
        nose.position = SCNVector3(0, -radius * 1.05, CGFloat(0.93 * h))
        n.addChildNode(nose)
        return n
    }

    private func mat(_ c: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = c
        m.lightingModel = .lambert
        return m
    }

    private func line(_ pts: [Vec3], color: NSColor) -> SCNNode {
        guard pts.count > 1 else { return SCNNode() }
        return lines(zip(pts, pts.dropFirst()).map { ($0, $1) }, color: color)
    }

    private func lines(_ segs: [(Vec3, Vec3)], color: NSColor) -> SCNNode {
        var verts: [SCNVector3] = []
        var idx: [Int32] = []
        for (a, b) in segs {
            idx.append(Int32(verts.count)); verts.append(SCNVector3(a.x, a.y, a.z))
            idx.append(Int32(verts.count)); verts.append(SCNVector3(b.x, b.y, b.z))
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        g.firstMaterial = m
        return SCNNode(geometry: g)
    }

    // MARK: The playhead (cheap: moves nodes)

    func pose(_ s: CameraSession, at t: Double) {
        for track in s.blocking?.characters ?? [] {
            guard let n = characters[track.modelId], let p = CameraMotion.character(track, at: t) else { continue }
            n.position = SCNVector3(p.position.x, p.position.y, p.position.z)
            n.eulerAngles = SCNVector3(0, 0, p.facingDeg * .pi / 180)
        }
        guard let pose = CameraMotion.camera(s.cameraPath, at: t), let cam = ShotCameraProjection(pose, aspect: aspect, sensorMm: sensor) else { return }
        // Rows: the camera's X (right), Y (up), Z (backward) axes, then its position (SceneKit cameras look down -Z).
        let r = cam.right, u = cam.up, f = cam.forward, p = cam.position
        shotCamera.transform = SCNMatrix4(m11: CGFloat(r.x), m12: CGFloat(r.y), m13: CGFloat(r.z), m14: 0,
                                          m21: CGFloat(u.x), m22: CGFloat(u.y), m23: CGFloat(u.z), m24: 0,
                                          m31: CGFloat(-f.x), m32: CGFloat(-f.y), m33: CGFloat(-f.z), m34: 0,
                                          m41: CGFloat(p.x), m42: CGFloat(p.y), m43: CGFloat(p.z), m44: 1)
        // The lens: the sensor spans the frame's longer side.
        let fov = CameraMotion.horizontalFov(focalMm: pose.focalMm, sensorMm: sensor)
        shotCamera.camera?.projectionDirection = aspect >= 1 ? .horizontal : .vertical
        shotCamera.camera?.fieldOfView = CGFloat(fov)
        if shotCamera.childNodes.isEmpty || abs(frustumFov - fov) > 0.01 {
            shotCamera.childNodes.forEach { $0.removeFromParentNode() }
            shotCamera.addChildNode(frustum(fov: fov))
            frustumFov = fov
        }
        shotCamera.childNodes.first?.isHidden = through
    }

    /// The camera as lines: apex at the lens, a 0.6 m deep pyramid with the frame's aspect, a tick on top.
    private func frustum(fov: Double) -> SCNNode {
        let d = 0.6
        let half = tan(fov / 2 * .pi / 180) * d
        let (hw, hh) = aspect >= 1 ? (half, half / aspect) : (half * aspect, half)
        let o = Vec3(0, 0, 0)
        let c = [Vec3(-hw, -hh, -d), Vec3(hw, -hh, -d), Vec3(hw, hh, -d), Vec3(-hw, hh, -d)]
        var segs: [(Vec3, Vec3)] = c.map { (o, $0) }
        for i in 0..<4 { segs.append((c[i], c[(i + 1) % 4])) }
        segs.append((Vec3(-hw * 0.3, hh, -d), Vec3(0, hh * 1.3, -d)))
        segs.append((Vec3(0, hh * 1.3, -d), Vec3(hw * 0.3, hh, -d)))
        let n = lines(segs, color: style.accent)
        let body = SCNNode(geometry: SCNBox(width: 0.16, height: 0.12, length: 0.2, chamferRadius: 0.01))
        body.geometry?.firstMaterial = mat(style.ink)
        body.position = SCNVector3(0, 0, 0.1)
        n.addChildNode(body)
        return n
    }

    // MARK: The view

    func look(throughCamera: Bool) {
        guard let v = view else { return }
        if throughCamera != through {
            through = throughCamera
            shotCamera.childNodes.first?.isHidden = throughCamera
        }
        if throughCamera {
            v.allowsCameraControl = false
            if v.pointOfView !== shotCamera { v.pointOfView = shotCamera }
        } else {
            if v.pointOfView === shotCamera || v.pointOfView == nil { v.pointOfView = orbitCamera }
            v.allowsCameraControl = true
        }
    }

    func resetView() {
        // Blender → SceneKit: (x, y, z) → (x, z, -y).
        func sk(_ v: Vec3) -> SCNVector3 { SCNVector3(v.x, v.z, -v.y) }
        orbitCamera.position = sk(framing.eye)
        orbitCamera.look(at: sk(framing.target), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        if let v = view, !through {
            v.pointOfView = orbitCamera
            v.defaultCameraController.target = sk(framing.target)
            v.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
        }
    }

    @objc func doubleClicked(_ g: NSClickGestureRecognizer) {
        through = false
        resetView()
    }
}
