import Foundation
import XCTest
@testable import MuseCore

/// Directed (Blender) mode, Direct with Claude and Connections: the pure logic behind the Mac views (plans/mcp-bridge.md "Phase 2 · UI").
final class CameraLogicTests: XCTestCase {
    private let now = 1_800_000_000_000.0
    private var seed: CameraSession { FakeCameraAPI.seedSession(now: now, relay: CameraRelayPresence(online: true, blender: true, addonVersion: "5.2")) }

    // MARK: Text

    func testIdChipStripAndCast() {
        XCTAssertEqual(CameraText.idChip("cs_7q2mxkd4f9"), "cs_7Q2M")
        XCTAssertEqual(CameraText.idChip("cs_ab"), "cs_AB")
        XCTAssertEqual(CameraText.stripMeta(seed), "9:16 · 24 fps · 6.0 s · rev 4")
        XCTAssertEqual(CameraText.cast(seed), "Demo model, Demo model B")
        XCTAssertEqual(CameraText.metres(1.5), "1.5 m")
        XCTAssertEqual(CameraText.size(4_200_000), "4.2 MB")
        XCTAssertEqual(CameraText.size(820_000), "820 KB")
        XCTAssertEqual(CameraText.ago(now - 120_000, now: now), "2 min ago")
        XCTAssertEqual(CameraText.ago(now - 10_000, now: now), "just now")
    }

    func testStatusPill() {
        var s = seed
        XCTAssertEqual(CameraText.statusPill(s).text, "Guides ready")
        s.status = "blocking"
        s.assets = []
        XCTAssertEqual(CameraText.statusPill(s).text, "Blocking")
        s.status = "drafting"
        XCTAssertEqual(CameraText.statusPill(s).text, "Drafting")
        s.status = "failed"
        XCTAssertEqual(CameraText.statusPill(s).tone, .bad)
    }

    func testFooterPrice() {
        XCTAssertEqual(CameraText.footer(seed.shotDraft), "Claude never spends money. Generating waits for your tap · est. $1.92 at HD.")
        XCTAssertEqual(CameraText.footer(nil), "Claude never spends money. Generating waits for your tap.")
        let d = CameraShotDraft(id: "sd", estimate: CameraEstimate(usd: 0.8))
        XCTAssertEqual(CameraText.footer(d), "Claude never spends money. Generating waits for your tap · est. $0.80.")
    }

    func testChatErrors() {
        XCTAssertEqual(CameraText.chatError(code: "chat_busy", message: "x"), "Claude is still working on this shot")
        XCTAssertTrue(CameraText.chatError(code: "director_unavailable", message: "x").contains("ANTHROPIC_API_KEY"))
        XCTAssertEqual(CameraText.chatError(code: "other", message: "Boom"), "Boom")
    }

    // MARK: Status rows

    func testClaudeRow() {
        var s = seed
        XCTAssertEqual(CameraStatus.claude(s, inAppChat: true, busy: true, now: now).detail, "Working…")
        s.claude = CameraClaudePresence(chatBusy: true)
        XCTAssertEqual(CameraStatus.claude(s, inAppChat: true, busy: false, now: now).detail, "Working…")
        s.claude = CameraClaudePresence(chatBusy: false, appLastSeenAt: now - 60_000)
        XCTAssertEqual(CameraStatus.claude(s, inAppChat: false, busy: false, now: now).detail, "Connected · your Claude app")
        s.claude = CameraClaudePresence(chatBusy: false, appLastSeenAt: now - 6 * 60_000)
        XCTAssertEqual(CameraStatus.claude(s, inAppChat: true, busy: false, now: now).detail, "In MUSE (this chat)")
        XCTAssertEqual(CameraStatus.claude(s, inAppChat: nil, busy: false, now: now).detail, "In MUSE (this chat)")
        let off = CameraStatus.claude(s, inAppChat: false, busy: false, now: now)
        XCTAssertEqual(off.detail, "Not set up")
        XCTAssertEqual(off.tone, .off)
    }

    func testBlenderRow() {
        let on = CameraStatus.blender(CameraRelayPresence(online: true, blender: true, addonVersion: "5.2"), machine: "Mac Studio")
        XCTAssertEqual(on.title, "Blender 5.2")
        XCTAssertEqual(on.detail, "Mac Studio · localhost")
        XCTAssertEqual(on.tone, .good)
        XCTAssertEqual(CameraStatus.blender(CameraRelayPresence(online: true, blender: false)).detail, "Mac app online · Blender not connected")
        XCTAssertEqual(CameraStatus.blender(CameraRelayPresence(online: false, blender: false)).detail, "Mac app offline")
        XCTAssertEqual(CameraStatus.blender(nil).title, "Blender")
    }

    func testRendersRow() {
        var s = seed
        XCTAssertEqual(CameraStatus.renders(s).detail, "Guides ready")
        let t = now
        s.assets = [
            CameraAsset(id: "a", kind: "greybox", state: "ready", createdAt: t - 600_000), // an older render
            CameraAsset(id: "b", kind: "greybox", state: "ready", createdAt: t),
            CameraAsset(id: "c", kind: "depth", state: "ready", createdAt: t + 1),
            CameraAsset(id: "d", kind: "keyframe_start", state: "pending", createdAt: t + 2),
            CameraAsset(id: "e", kind: "keyframe_mid", state: "pending", createdAt: t + 3),
            CameraAsset(id: "f", kind: "keyframe_end", state: "pending", createdAt: t + 4),
        ]
        // Batch = this render's files: b…f, 2 ready → uploading the 3rd of 5.
        XCTAssertEqual(CameraStatus.renders(s).detail, "Uploading 3 of 5 to MUSE")
        s.assets[3].state = "ready"
        XCTAssertEqual(CameraStatus.renders(s).detail, "Uploading 4 of 5 to MUSE")
        s.assets = []
        XCTAssertEqual(CameraStatus.renders(s).detail, "None yet")
        let rows = CameraStatus.rows(seed, inAppChat: true, busy: false, now: now)
        XCTAssertEqual(rows.map(\.title), ["Claude session", "Blender 5.2", "Renders"])
    }

    // MARK: Motion and geometry

    func testEase() {
        XCTAssertEqual(CameraEase.apply(nil, 0.5), 0.5)
        XCTAssertEqual(CameraEase.apply("in", 0.5), 0.25)
        XCTAssertEqual(CameraEase.apply("out", 0.5), 0.75)
        XCTAssertEqual(CameraEase.apply("in_out", 0.5), 0.5)
        XCTAssertEqual(CameraEase.apply("in_out", 0.25), 0.15625, accuracy: 1e-9)
        XCTAssertEqual(CameraEase.apply("in", 2), 1)
    }

    func testInterpolation() throws {
        let path = CameraPath(keyframes: [CamKey(t: 0, position: Vec3(0, -4, 1.5), target: Vec3(0, 0, 1.5), focalMm: 35, ease: "in"),
                                          CamKey(t: 2, position: Vec3(0, -2, 1.5), focalMm: 50)])
        let mid = try XCTUnwrap(CameraMotion.camera(path, at: 1))
        XCTAssertEqual(mid.position.y, -3.5, accuracy: 1e-9) // ease in: u = 0.25
        XCTAssertEqual(mid.focalMm, 38.75, accuracy: 1e-9)
        XCTAssertEqual(mid.target, Vec3(0, 0, 1.5)) // the missing target borrows the neighbour's
        XCTAssertEqual(CameraMotion.camera(path, at: -1)?.position, Vec3(0, -4, 1.5))
        XCTAssertEqual(CameraMotion.camera(path, at: 9)?.position, Vec3(0, -2, 1.5))
        XCTAssertNil(CameraMotion.camera(nil, at: 0))

        let track = CameraBlockingTrack(modelId: "m", keyframes: [CharKey(t: 1, position: Vec3(0, 0), facingDeg: 350, action: "walk"),
                                                                 CharKey(t: 3, position: Vec3(2, 0), facingDeg: 10, action: "turn")])
        let c = try XCTUnwrap(CameraMotion.character(track, at: 2))
        XCTAssertEqual(c.position.x, 1, accuracy: 1e-9)
        XCTAssertEqual(c.facingDeg, 360, accuracy: 1e-9) // shortest way round
        XCTAssertEqual(c.action, "walk")
        XCTAssertEqual(CameraMotion.character(track, at: 3.5)?.action, "turn")
        XCTAssertEqual(CameraMotion.character(track, at: 0)?.position, Vec3(0, 0)) // before the first key: holds there
        let face0 = CharacterPose(position: Vec3(0, 0), facingDeg: 0, action: nil).facing
        XCTAssertEqual(face0.x, 0, accuracy: 1e-9)
        XCTAssertEqual(face0.y, -1, accuracy: 1e-9)
    }

    func testFov() {
        XCTAssertEqual(CameraMotion.horizontalFov(focalMm: 18), 90, accuracy: 1e-9)
        XCTAssertEqual(CameraMotion.horizontalFov(focalMm: 35), 54.43, accuracy: 0.01)
    }

    func testGeometryFitsBoundsWithMargin() {
        let g = PlanGeometry(points: [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 2)], size: CGSize(width: 600, height: 400))
        XCTAssertEqual(g.bounds, CGRect(x: -1, y: -1, width: 6, height: 4))
        XCTAssertEqual(g.scale, 100, accuracy: 1e-9)
        // (-1, 3) is the top-left corner; +Y is up on screen.
        XCTAssertEqual(g.point(CGPoint(x: -1, y: 3)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(g.point(Vec3(0, 0)), CGPoint(x: 100, y: 300))
        XCTAssertEqual(g.world(CGPoint(x: 100, y: 300)), CGPoint(x: 0, y: 0))
        // A taller box is centred horizontally.
        let h = PlanGeometry(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 2)], size: CGSize(width: 400, height: 400))
        XCTAssertEqual(h.scale, 100, accuracy: 1e-9)
        XCTAssertEqual(h.origin.x, 100, accuracy: 1e-9)
        let grid = g.grid(step: 1)
        XCTAssertEqual(grid.xs.count, 7)
        XCTAssertEqual(grid.ys.count, 5)
    }

    func testSessionGeometryAndSideView() {
        let g = PlanGeometry(session: seed, size: CGSize(width: 760, height: 420))
        // Every camera, target and character point is inside the drawing.
        for k in seed.cameraPath!.keyframes {
            let p = g.point(k.position)
            XCTAssertTrue((0...760).contains(p.x) && (0...420).contains(p.y))
        }
        let side = PlanGeometry(session: seed, size: CGSize(width: 760, height: 420), projection: .side)
        XCTAssertGreaterThanOrEqual(side.bounds.maxY, 1.72 + 1) // the tallest head + margin
        XCTAssertNil(side.viewCone(CameraPose(position: Vec3(0, 0, 1), target: Vec3(0, 3, 1), focalMm: 35)))
    }

    func testViewCone() throws {
        let g = PlanGeometry(points: [CGPoint(x: -5, y: -5), CGPoint(x: 5, y: 5)], size: CGSize(width: 120, height: 120))
        let cone = try XCTUnwrap(g.viewCone(CameraPose(position: Vec3(0, 0, 1.5), target: Vec3(0, 2, 1.5), focalMm: 18), length: 2))
        XCTAssertEqual(cone.count, 3)
        let apex = g.point(Vec3(0, 0))
        XCTAssertEqual(cone[0], apex)
        // 90° FOV toward +Y: the edges end at (±2, 2).
        let l = g.world(cone[1]), r = g.world(cone[2])
        XCTAssertEqual(l.x, -2, accuracy: 1e-6)
        XCTAssertEqual(l.y, 2, accuracy: 1e-6)
        XCTAssertEqual(r.x, 2, accuracy: 1e-6)
        XCTAssertNil(g.viewCone(CameraPose(position: Vec3(0, 0, 1), target: Vec3(0, 0, 3), focalMm: 35)))
        XCTAssertEqual(PlanGeometry.cameraLabel(CameraPose(position: Vec3(0, 0, 1.5), target: Vec3(0, 1, 1.5), focalMm: 35)), "CAM A · 35 mm · 1.5 m")
    }

    func testTicks() {
        let g = PlanGeometry(session: seed, size: CGSize(width: 760, height: 420))
        let ticks = CameraPathTicks.ticks(seed.blocking!.characters[0].keyframes, g)
        XCTAssertEqual(ticks.map(\.label), ["0.0s", "1.2s", "3.5s"])
        XCTAssertEqual(CameraPathTicks.ruler(duration: 6).map(\.label), ["0s", "1s", "2s", "3s", "4s", "5s", "6s"])
        XCTAssertEqual(CameraPathTicks.ruler(duration: 2.5).count, 3)
    }

    // MARK: Timeline

    func testCameraMoveLabels() {
        let tg = Vec3(0, 0, 1.5)
        let push = CameraTimeline.cameraMove(CamKey(t: 0, position: Vec3(0, -3, 1.5), ease: "in_out"), CamKey(t: 4, position: Vec3(0, -2.6, 1.5)), targetA: tg, targetB: tg)
        XCTAssertEqual(push.label, "push 0.4 m · ease in-out")
        XCTAssertFalse(push.orbit)
        let pull = CameraTimeline.cameraMove(CamKey(t: 0, position: Vec3(0, -2, 1.5)), CamKey(t: 4, position: Vec3(0, -3, 1.5)), targetA: tg, targetB: tg)
        XCTAssertEqual(pull.label, "pull 1.0 m")
        let orbit = CameraTimeline.cameraMove(CamKey(t: 0, position: Vec3(0, -2, 1.5)), CamKey(t: 4, position: Vec3(2, 0, 1.5)), targetA: tg, targetB: tg)
        XCTAssertEqual(orbit.label, "orbit 90°")
        XCTAssertTrue(orbit.orbit)
        let track = CameraTimeline.cameraMove(CamKey(t: 0, position: Vec3(-1, -3, 1.5)), CamKey(t: 4, position: Vec3(0, -3, 1.5)), targetA: Vec3(-1, 0, 1.5), targetB: Vec3(0, 0, 1.5))
        XCTAssertEqual(track.label, "track 1.0 m")
        let rise = CameraTimeline.cameraMove(CamKey(t: 0, position: Vec3(0, -3, 0.5)), CamKey(t: 4, position: Vec3(0, -3, 2.5)), targetA: tg, targetB: tg)
        XCTAssertEqual(rise.label, "rise 2.0 m")
        let zoom = CameraTimeline.cameraMove(CamKey(t: 0, position: Vec3(0, -3, 1.5), focalMm: 35), CamKey(t: 4, position: Vec3(0, -3, 1.5), focalMm: 50), targetA: tg, targetB: tg)
        XCTAssertEqual(zoom.label, "zoom 35→50 mm")
        let hold = CameraTimeline.cameraMove(CamKey(t: 0, position: Vec3(0, -3, 1.5)), CamKey(t: 4, position: Vec3(0, -3, 1.5)), targetA: tg, targetB: tg)
        XCTAssertEqual(hold.label, "hold")
    }

    func testTracks() {
        let tracks = CameraTimeline.tracks(seed)
        XCTAssertEqual(tracks.map(\.name), ["CAMERA", "DEMO MODEL", "DEMO MODEL B", "CUTS"])
        XCTAssertEqual(tracks[0].keys, [0, 4.5, 6])
        XCTAssertEqual(tracks[0].spans.count, 2)
        XCTAssertTrue(tracks[0].spans[0].label.hasPrefix("push"))
        XCTAssertTrue(tracks[0].spans[0].label.hasSuffix("· ease in-out"))
        XCTAssertTrue(tracks[0].spans[1].label.hasPrefix("orbit"))
        XCTAssertTrue(tracks[0].spans[1].accent)
        // Mia: 0–1.2 action, 1.2–3.5 derived walk speed, 3.5–end
        let a = tracks[1].spans
        XCTAssertEqual(a.map(\.label)[0], "walk → counter · 1.1 m/s")
        XCTAssertTrue(a[1].label.hasPrefix("walk · "))
        XCTAssertEqual(a[2].label, "turn · smile to camera")
        XCTAssertEqual(a[2].end, 6)
        // Noor holds (her note) until her first key at 3 s.
        let b = tracks[2].spans
        XCTAssertEqual(b[0].label, "waits by window")
        XCTAssertTrue(b[0].muted)
        XCTAssertEqual(b[0].end, 3)
        XCTAssertEqual(CameraTimeline.playheadLabel(2.4), "2.4 s")
        XCTAssertEqual(CameraTimeline.endLabel(6), "end 6.0 s")
    }

    func testScrubTime() {
        XCTAssertEqual(CameraTimeline.time(x: 300, width: 600, duration: 6, fps: 24), 3)
        XCTAssertEqual(CameraTimeline.time(x: -20, width: 600, duration: 6, fps: 24), 0)
        XCTAssertEqual(CameraTimeline.time(x: 900, width: 600, duration: 6, fps: 24), 6)
        XCTAssertEqual(CameraTimeline.time(x: 101, width: 600, duration: 6, fps: 24), 1.0)
    }

    // MARK: Drag

    func testDragMovesKeyAtPlayhead() throws {
        let s = seed
        let u = try XCTUnwrap(CameraDrag.update(s, handle: .camera, at: 4.5, to: CGPoint(x: 1, y: -2)))
        XCTAssertNil(u.characters)
        let k = try XCTUnwrap(u.camera?.keyframes[1])
        XCTAssertEqual(k.position, Vec3(1, -2, 1.5)) // height kept
        XCTAssertEqual(u.camera?.keyframes.count, 3)
    }

    func testDragInsertsKeyBetween() throws {
        let s = seed
        let u = try XCTUnwrap(CameraDrag.update(s, handle: .character(SampleData.demo), at: 2.4, to: CGPoint(x: 0, y: 1)))
        let keys = try XCTUnwrap(u.characters?.first { $0.modelId == SampleData.demo }?.keyframes)
        XCTAssertEqual(keys.map(\.t), [0, 1.2, 2.4, 3.5])
        XCTAssertEqual(keys[2].position, Vec3(0, 1))
        XCTAssertNil(keys[2].action)
        XCTAssertEqual(u.characters?.count, 2) // the whole blocking goes up
        let applied = CameraDrag.applying(u, to: s)
        XCTAssertEqual(applied.blocking?.characters[0].keyframes.count, 4)
        // Camera between keys: keeps the interpolated height, lens and look-at.
        let c = try XCTUnwrap(CameraDrag.update(s, handle: .camera, at: 5, to: CGPoint(x: 2, y: -2)))
        XCTAssertEqual(c.camera?.keyframes.map(\.t), [0, 4.5, 5, 6])
        XCTAssertEqual(c.camera?.keyframes[2].focalMm, 35)
        XCTAssertNotNil(c.camera?.keyframes[2].target)
        XCTAssertNil(CameraDrag.update(s, handle: .character("nobody"), at: 1, to: .zero))
    }

    func testHit() {
        let s = seed
        let g = PlanGeometry(session: s, size: CGSize(width: 760, height: 420))
        let cam = g.point(CameraMotion.camera(s.cameraPath, at: 0)!.position)
        XCTAssertEqual(CameraDrag.hit(cam, session: s, at: 0, geometry: g), .camera)
        let mia = g.point(CameraMotion.character(s.blocking!.characters[0], at: 0)!.position)
        XCTAssertEqual(CameraDrag.hit(CGPoint(x: mia.x + 4, y: mia.y), session: s, at: 0, geometry: g), .character(SampleData.demo))
        XCTAssertNil(CameraDrag.hit(CGPoint(x: -500, y: -500), session: s, at: 0, geometry: g))
    }

    // MARK: Transcript

    func testToolChipsCollapse() {
        let chips = ToolChip.collapse([
            CameraToolStep(name: "blender_setup_scene", ok: true), CameraToolStep(name: "blender_place_character", ok: true),
            CameraToolStep(name: "blender_place_character", ok: false), CameraToolStep(name: "set_camera_path", ok: true),
            CameraToolStep(name: "blender_place_character", ok: true),
        ])
        XCTAssertEqual(chips.map(\.text), ["SETUP_SCENE", "PLACE_CHARACTER ×2", "SET_CAMERA_PATH", "PLACE_CHARACTER"])
        XCTAssertFalse(chips[1].ok)
        XCTAssertTrue(chips[3].ok)
    }

    func testTranscriptItems() {
        let items = CameraTranscript.items(seed.messages ?? [], devices: ["cm_1": "Mac app"])
        XCTAssertEqual(items.count, 2)
        guard case .user(_, let label, let text) = items[0], case .claude(_, let cl, let ctext, let chips) = items[1] else { return XCTFail("shape") }
        XCTAssertEqual(label, "You · Mac app")
        XCTAssertTrue(text.hasPrefix("Block a 6 s walk-and-talk"))
        XCTAssertEqual(cl, "Claude")
        XCTAssertTrue(ctext.hasPrefix("Built the café"))
        XCTAssertEqual(chips.map(\.text), ["SETUP_SCENE", "PLACE_CHARACTER ×2", "RENDER_GUIDES"])
        let none = CameraTranscript.items(seed.messages ?? [])
        if case .user(_, let l, _) = none[0] { XCTAssertEqual(l, "You") }
        let mcp = CameraTranscript.items([CameraMessage(id: "x", role: "assistant", source: "mcp", text: "Done in Blender", createdAt: 1),
                                          CameraMessage(id: "n", role: "user", source: "app", text: "keep her left", createdAt: 2)])
        if case .claude(_, let l, _, _) = mcp[0] { XCTAssertEqual(l, "Your Claude") } else { XCTFail() }
        if case .user(_, let l, _) = mcp[1] { XCTAssertEqual(l, "You · note") } else { XCTFail() }
    }

    // MARK: Working strip

    func testChatTurnProgress() {
        var turn = ChatTurn(startRevision: 4)
        XCTAssertEqual(turn.title, "Claude · working on rev 5")
        XCTAssertEqual(turn.progress(), 0)
        turn.apply(.text("Slower orbit, keep Noor’s face"))
        XCTAssertEqual(turn.quote, "↳ “Slower orbit, keep Noor’s face”")
        turn.apply(.tool(id: "1", name: "set_camera_path", status: "running", summary: nil))
        XCTAssertEqual(turn.quote, "↳ set camera path")
        turn.apply(.tool(id: "1", name: "set_camera_path", status: "done", summary: "easing the orbit to 45°/s"))
        turn.apply(.tool(id: "2", name: "blender_render_guides", status: "running", summary: nil))
        turn.apply(.waiting(reason: "blender"))
        XCTAssertTrue(turn.quote!.hasPrefix("↳ Waiting for Blender on your Mac"))
        XCTAssertEqual(turn.stepsSeen, 2)
        XCTAssertEqual(turn.stepsDone, 1)
        XCTAssertEqual(turn.percent(), "50%")
        XCTAssertEqual(turn.percent(renderProgress: 0.64), "64%")
        turn.apply(.tool(id: "2", name: "blender_render_guides", status: "error", summary: nil))
        XCTAssertEqual(turn.progress(), 1)
        XCTAssertEqual(turn.steps.map(\.ok), [true, false])
        turn.apply(.error(code: "chat_busy", message: "busy"))
        XCTAssertTrue(turn.finished)
        XCTAssertEqual(turn.error, "Claude is still working on this shot")
    }

    // MARK: Guides and history

    func testGuides() {
        let items = CameraGuides.items(seed.assets)
        XCTAssertEqual(items.map(\.label), ["GREYBOX", "DEPTH", "START", "MID", "END", "camera.json"])
        XCTAssertTrue(items[0].isVideo)
        XCTAssertTrue(items[2].isImage)
        XCTAssertEqual(items[0].size, "4.2 MB")
        XCTAssertEqual(items[0].source, "Mac app")
        XCTAssertEqual(CameraGuides.card(seed)?.map(\.label), ["GREYBOX", "DEPTH", "START", "MID", "END"])
        var s = seed
        s.assets.removeAll { $0.kind == "greybox" }
        XCTAssertNil(CameraGuides.card(s))
        // Newest of a kind first, pending ones left out.
        let two = CameraGuides.items([CameraAsset(id: "old", kind: "greybox", state: "ready", createdAt: 1), CameraAsset(id: "new", kind: "greybox", state: "ready", createdAt: 2),
                                      CameraAsset(id: "p", kind: "depth", state: "pending", createdAt: 3)])
        XCTAssertEqual(two.map(\.id), ["new", "old"])
        XCTAssertEqual(CameraGuides.items(two.map(\.asset), latestOnly: true).map(\.id), ["new"])
    }

    func testCameraViewStill() {
        var s = seed
        for i in s.assets.indices { s.assets[i].url = "https://x/\(s.assets[i].id)" }
        XCTAssertEqual(CameraGuides.still(s, at: 0.4)?.kind, "keyframe_start")
        XCTAssertEqual(CameraGuides.still(s, at: 3.2)?.kind, "keyframe_mid")
        XCTAssertEqual(CameraGuides.still(s, at: 5.9)?.kind, "keyframe_end")
        s.assets = [CameraAsset(id: "pv", kind: "preview", state: "ready", url: "https://x/pv", createdAt: 1)]
        XCTAssertEqual(CameraGuides.still(s, at: 1)?.id, "pv")
        s.assets = []
        XCTAssertNil(CameraGuides.still(s, at: 1))
    }

    func testHistory() {
        let h = CameraHistory.entries(seed, now: seed.updatedAt + 60_000)
        XCTAssertFalse(h.isEmpty)
        XCTAssertTrue(h[0].title.hasPrefix("rev 4 · "))
        XCTAssertTrue(h.dropFirst().allSatisfy { !$0.title.hasPrefix("rev") })
        XCTAssertEqual(h, h.sorted { $0.at > $1.at })
        // The relay's six uploads within seconds are one line.
        let uploads = h.filter { $0.title.contains("Mac app") }
        XCTAssertEqual(uploads.count, 1)
        XCTAssertTrue(uploads[0].title.contains("greybox ready"))
        XCTAssertTrue(h.contains { $0.title.contains("Claude (chat) · setup scene, place character and render guides") })
        XCTAssertEqual(CameraHistory.join(["a", "b", "c"]), "a, b and c")
    }

    // MARK: Live events

    func testApplyLiveEvents() {
        var list = [seed]
        var other = CameraSession(id: "cs_other", title: "Other", updatedAt: seed.updatedAt + 1)
        CameraSessions.apply(&list, .upsert(other))
        XCTAssertEqual(list.map(\.id), ["cs_other", FakeCameraAPI.seedId])
        // An upsert without messages keeps the loaded ones and moves the session up.
        var changed = seed
        changed.messages = nil
        changed.revision = 5
        changed.updatedAt = seed.updatedAt + 10
        CameraSessions.apply(&list, .upsert(changed))
        XCTAssertEqual(list[0].id, FakeCameraAPI.seedId)
        XCTAssertEqual(list[0].revision, 5)
        XCTAssertEqual(list[0].messages?.count, seed.messages?.count)
        let m = CameraMessage(id: "cm_new", role: "assistant", source: "mcp", text: "hi", createdAt: 9)
        CameraSessions.apply(&list, .message(sessionId: FakeCameraAPI.seedId, m))
        CameraSessions.apply(&list, .message(sessionId: FakeCameraAPI.seedId, m))
        XCTAssertEqual(list[0].messages?.filter { $0.id == "cm_new" }.count, 1)
        CameraSessions.apply(&list, .asset(sessionId: FakeCameraAPI.seedId, CameraAsset(id: "ca_new", kind: "pose", state: "pending")))
        CameraSessions.apply(&list, .asset(sessionId: FakeCameraAPI.seedId, CameraAsset(id: "ca_new", kind: "pose", state: "ready")))
        XCTAssertEqual(list[0].assets.last?.state, "ready")
        CameraSessions.apply(&list, .relay(CameraRelayPresence(online: false, blender: false)))
        XCTAssertEqual(list.map { $0.relay?.online }, [false, false])
        other.title = "x"
        CameraSessions.apply(&list, .delete("cs_other"))
        XCTAssertEqual(list.count, 1)
        CameraSessions.apply(&list, .message(sessionId: "cs_missing", m)) // ignored
    }

    func testHandoff() throws {
        let json = try XCTUnwrap(CameraSessions.handoff(seed.shotDraft))
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .object(let o) = v, case .object(let guide)? = o["guide"], case .object(let kf)? = guide["keyframes"], case .object(let video)? = guide["video"] else {
            return XCTFail("shape: \(json)")
        }
        XCTAssertEqual(o["mode"], .string("directed"))
        XCTAssertEqual(guide["cameraSessionId"], .string(FakeCameraAPI.seedId))
        XCTAssertEqual(guide["use"], .string("blocking"))
        XCTAssertNotNil(video["key"])
        XCTAssertNotNil(kf["start"])
        XCTAssertTrue(json.contains("\"/uploads/cam/"))
        XCTAssertTrue(CameraSessions.handoffHasGuide(seed.shotDraft))
        XCTAssertNil(CameraSessions.handoff(nil))
        XCTAssertNil(CameraSessions.handoff(CameraShotDraft(id: "x", request: .object(["prompt": .string("p")]))))
    }

    // MARK: Connections

    func testConnectionSnippets() {
        XCTAssertEqual(CameraConnectionsText.claudeCode(url: "https://api.muse/mcp", token: "muse_pat_x"),
                       "claude mcp add --transport http muse https://api.muse/mcp --header \"Authorization: Bearer muse_pat_x\"")
        let desktop = CameraConnectionsText.claudeDesktop(url: "https://api.muse/mcp", token: nil)
        XCTAssertNoThrow(try JSONDecoder().decode(JSONValue.self, from: Data(desktop.utf8)))
        XCTAssertTrue(desktop.contains("Bearer muse_pat_…"))
        let t = McpToken(id: "pat_1", name: "Laptop", prefix: "muse_pat_ab12", createdAt: now - 2 * 86_400_000, lastUsedAt: now - 180_000)
        XCTAssertEqual(CameraConnectionsText.prefix(t), "muse_pat_ab12…")
        XCTAssertEqual(CameraConnectionsText.tokenLine(t, now: now), "Created 2 d ago · last used 3 min ago")
        XCTAssertEqual(CameraConnectionsText.installSteps.count, 3)
        XCTAssertEqual(CameraConnectionsText.inAppChat(false), "Needs ANTHROPIC_API_KEY on the server")
    }
}

/// Wire formats: SSE chat events, live events and the server's JSON.
final class CameraWireTests: XCTestCase {
    func testChatStream() {
        let body = """
        : keep-alive

        data: {"type":"message","message":{"id":"cm_1","role":"user","source":"chat","text":"push in","createdAt":1}}

        data: {"type":"text","delta":"On it"}

        data: {"type":"tool","id":"tu_1","name":"blender_set_camera","status":"running"}

        data: {"type":"waiting","reason":"blender"}

        data: {"type":"tool","id":"tu_1","name":"blender_set_camera","status":"done","summary":"3 keys"}

        data: {"type":"future_thing","x":1}

        data: {"type":"done","stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":5,"cacheReadTokens":0,"cacheWriteTokens":0}}

        """
        let events = ChatStreamParser.parseAll(body)
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events[1], .text("On it"))
        XCTAssertEqual(events[2], .tool(id: "tu_1", name: "blender_set_camera", status: "running", summary: nil))
        XCTAssertEqual(events[3], .waiting(reason: "blender"))
        XCTAssertEqual(events[4], .tool(id: "tu_1", name: "blender_set_camera", status: "done", summary: "3 keys"))
        if case .done(let r, let u) = events[5] { XCTAssertEqual(r, "end_turn"); XCTAssertEqual(u?.inputTokens, 10) } else { XCTFail() }
        if case .message(let m) = events[0] { XCTAssertEqual(m.text, "push in") } else { XCTFail() }
        XCTAssertEqual(ChatStreamParser.parseAll("data: {\"type\":\"error\",\"code\":\"blender_offline\",\"error\":\"Mac offline\"}"),
                       [.error(code: "blender_offline", message: "Mac offline")])
        // CRLF line endings and no trailing blank line.
        XCTAssertEqual(ChatStreamParser.parseAll("data: {\"type\":\"text\",\"delta\":\"a\"}\r\n\r\ndata: {\"type\":\"text\",\"delta\":\"b\"}"), [.text("a"), .text("b")])
    }

    func testLiveEvents() {
        var f = CameraLiveEventFilter()
        func feed(_ json: String) -> CameraLiveEvent? {
            _ = f.feed("data: \(json)")
            return f.feed("")
        }
        XCTAssertEqual(feed(#"{"type":"camera","op":"delete","id":"cs_1"}"#), .delete("cs_1"))
        XCTAssertEqual(feed(#"{"type":"blender","op":"relay","online":true,"blender":true,"addonVersion":"1.8"}"#),
                       .relay(CameraRelayPresence(online: true, blender: true, addonVersion: "1.8")))
        XCTAssertEqual(feed(#"{"type":"blender","op":"relay","online":false,"blender":true}"#), .relay(CameraRelayPresence(online: false, blender: false)))
        XCTAssertNil(feed(#"{"type":"job","job":{}}"#))
        XCTAssertNil(feed(#"{"type":"blender","op":"call","call":{"id":"bc_1"}}"#))
        if case .asset(let sid, let a)? = feed(#"{"type":"camera","op":"asset","sessionId":"cs_1","asset":{"id":"ca_1","kind":"greybox","state":"ready","contentType":"video/mp4","source":"relay","url":"https://r2/x","createdAt":5}}"#) {
            XCTAssertEqual(sid, "cs_1")
            XCTAssertEqual(a.source, "relay")
            XCTAssertEqual(a.url, "https://r2/x")
        } else { XCTFail() }
        if case .message(let sid, let m)? = feed(#"{"type":"camera","op":"message","sessionId":"cs_1","message":{"id":"cm_1","role":"tool","source":"mcp","text":"","tool":{"name":"set_camera_path","ok":true,"summary":"3 keys"},"createdAt":7}}"#) {
            XCTAssertEqual(sid, "cs_1")
            XCTAssertEqual(m.tool?.name, "set_camera_path")
        } else { XCTFail() }
    }

    /// A session as the server's `view()` writes it (compact: optional fields left out).
    func testDecodeServerSession() throws {
        let json = """
        {"type":"camera","op":"upsert","session":{"id":"cs_abcdef123456","title":"Kitchen","brief":"","status":"blocking","aspect":"9:16","fps":24,"durationSec":6,
         "presets":{},"characters":[{"modelId":"m_1","name":"Mia","heightM":1.68}],
         "cameraPath":{"keyframes":[{"t":0,"position":[0,-3,1.5],"target":[0,0,1.4],"focalMm":35,"ease":"in_out"},{"t":6,"position":[0,-2.6,1.5]}]},
         "blocking":{"characters":[{"modelId":"m_1","keyframes":[{"t":0,"position":[-1,0,0],"facingDeg":-90,"action":"walk"}]}]},
         "assets":[],"camera":{"mode":"directed","directed":{"cameraSessionId":"cs_abcdef123456","guideAssets":{},"trajectories":{},"keyframes":[]}},
         "revision":3,"relay":{"online":true,"blender":false},"claude":{"chatBusy":false},"createdAt":1,"updatedAt":2,
         "shotDraft":{"id":"sd_1","state":"draft","source":"camera","prompt":"p","targetModel":"kling-v4.0","durationSec":6,"aspect":"9:16","estimate":{"usd":0.85,"tokens":85},
           "camera":{"mode":"directed"},"createdAt":3,"request":{"quality":"cinema","camera":{"mode":"directed"}}}}}
        """
        guard case .upsert(let s)? = CameraLiveEvent.parse(Data(json.utf8)) else { return XCTFail("not decoded") }
        XCTAssertEqual(s.characters.first?.name, "Mia")
        XCTAssertEqual(s.cameraPath?.keyframes.first?.position, Vec3(0, -3, 1.5))
        XCTAssertEqual(s.blocking?.characters.first?.keyframes.first?.facingDeg, -90)
        XCTAssertEqual(s.revision, 3)
        XCTAssertEqual(s.shotDraft?.estimate?.usd, 0.85)
        XCTAssertEqual(CameraText.footer(s.shotDraft), "Claude never spends money. Generating waits for your tap · est. $0.85 at Cinema.")
        XCTAssertNil(s.messages)
        // Round trip (the PUT body encodes Vec3 as arrays).
        let body = try JSONEncoder().encode(CameraPathUpdate(camera: s.cameraPath))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("[0,-3,1.5]"))
    }

    func testDecodeConnectionsAndTokens() throws {
        let c = try JSONDecoder().decode(CameraConnections.self, from: Data(#"{"relay":{"online":true,"blender":true,"addonVersion":"1.8"},"claudeApp":{"tokens":2},"mcpUrl":"https://x/mcp","inAppChat":false,"docsUrl":"https://d"}"#.utf8))
        XCTAssertEqual(c.claudeApp.tokens, 2)
        XCTAssertNil(c.claudeApp.lastSeenAt)
        XCTAssertFalse(c.inAppChat)
        let t = try JSONDecoder().decode(McpTokenCreated.self, from: Data(#"{"id":"pat_1","name":"Laptop","prefix":"muse_pat_ab12","token":"muse_pat_ab12cd","createdAt":5}"#.utf8))
        XCTAssertEqual(t.listed.prefix, "muse_pat_ab12")
    }

    func testIdsInPaths() {
        XCTAssertNoThrow(try CameraIds.check("cs_abc-123"))
        XCTAssertThrowsError(try CameraIds.check("../x"))
        XCTAssertThrowsError(try CameraIds.check(""))
    }
}

/// The in-process fake behaves like the server for the screens.
final class CameraFakeAPITests: XCTestCase {
    private func api(inAppChat: Bool = true) -> FakeCameraAPI { FakeCameraAPI(stepDelay: 0, inAppChat: inAppChat) }

    func testSeedAndCrud() async throws {
        let a = api()
        let list = try await a.listSessions()
        XCTAssertEqual(list.map(\.id), [FakeCameraAPI.seedId])
        XCTAssertNil(list[0].messages)
        let one = try await a.session(FakeCameraAPI.seedId)
        XCTAssertEqual(one.messages?.count, 6)
        let created = try await a.createSession(CameraSessionCreate(title: "Rooftop", characters: [.init(modelId: SampleData.demo)]))
        XCTAssertTrue(created.id.hasPrefix("cs_"))
        XCTAssertEqual(created.characters.first?.name, "Demo model")
        let firstId = try await a.listSessions().first?.id
        XCTAssertEqual(firstId, created.id)
        let patched = try await a.patchSession(created.id, CameraSessionPatch(title: "Rooftop 2", revision: created.revision))
        XCTAssertEqual(patched.revision, created.revision + 1)
        do {
            _ = try await a.patchSession(created.id, CameraSessionPatch(title: "x", revision: 1))
            XCTFail("stale")
        } catch let e as ApiError { XCTAssertEqual(e.code, "stale_revision") }
        try await a.deleteSession(created.id)
        let left = try await a.listSessions()
        XCTAssertEqual(left.count, 1)
    }

    func testPathDraftAndJob() async throws {
        let a = api()
        let s = try await a.createSession(CameraSessionCreate(characters: [.init(modelId: SampleData.demo)]))
        let after = try await a.setPath(s.id, CameraPathUpdate(camera: CameraPath(keyframes: [CamKey(t: 0, position: Vec3(0, -3, 1.5))]),
                                                               characters: [CameraBlockingTrack(modelId: SampleData.demo, keyframes: [CharKey(t: 0, position: Vec3(0, 0))])]))
        XCTAssertEqual(after.status, "blocking")
        XCTAssertEqual(after.blocking?.characters.count, 1)
        do {
            _ = try await a.setPath(s.id, CameraPathUpdate(characters: [CameraBlockingTrack(modelId: "m_x", keyframes: [])]))
            XCTFail("cast")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        do {
            _ = try await a.linkJob(s.id, jobId: "j")
            XCTFail("no draft")
        } catch let e as ApiError { XCTAssertEqual(e.code, "no_draft") }
        let d = try await a.createShotDraft(s.id, CameraShotDraftRequest())
        XCTAssertFalse(CameraSessions.handoffHasGuide(d)) // no greybox yet
        XCTAssertNotNil(CameraSessions.handoff(d))
        let seeded = try await a.createShotDraft(FakeCameraAPI.seedId, CameraShotDraftRequest())
        XCTAssertTrue(CameraSessions.handoffHasGuide(seeded))
        let linked = try await a.linkJob(s.id, jobId: "j1")
        XCTAssertEqual(linked.status, "generating")
    }

    func testChatTurnAndEvents() async throws {
        let a = api()
        let stream = a.events()
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first, .connected)
        var turn = ChatTurn(startRevision: 4)
        var all: [ChatEvent] = []
        for try await e in a.chat(FakeCameraAPI.seedId, message: "lower the camera, lens 50") {
            all.append(e)
            turn.apply(e)
        }
        XCTAssertTrue(turn.finished)
        XCTAssertNil(turn.error)
        XCTAssertEqual(turn.stepsDone, 2)
        XCTAssertEqual(turn.progress(), 1)
        if case .message(let m) = all[0] { XCTAssertEqual(m.role, "user") } else { XCTFail() }
        let s = try await a.session(FakeCameraAPI.seedId)
        XCTAssertEqual(s.revision, 5)
        XCTAssertEqual(s.messages?.last?.role, "assistant")
        // The live stream saw the user message, the path upsert and the assistant message.
        var seen: [CameraLiveEvent] = []
        for _ in 0..<3 { if let e = await it.next() { seen.append(e) } }
        XCTAssertTrue(seen.contains { if case .upsert = $0 { return true } else { return false } })
    }

    func testChatErrors() async {
        let off = api(inAppChat: false)
        do {
            for try await _ in off.chat(FakeCameraAPI.seedId, message: "hi") {}
            XCTFail("unavailable")
        } catch let e as ApiError { XCTAssertEqual(e.code, "director_unavailable") } catch { XCTFail("\(error)") }
        do {
            for try await _ in api().chat("cs_missing", message: "hi") {}
            XCTFail("missing")
        } catch let e as ApiError { XCTAssertEqual(e.code, "not_found") } catch { XCTFail("\(error)") }
    }

    func testTokensAndConnections() async throws {
        let a = api()
        var c = try await a.connections()
        XCTAssertEqual(c.claudeApp.tokens, 0)
        XCTAssertTrue(c.inAppChat)
        let t = try await a.createToken(name: "Laptop", expiresDays: 30)
        XCTAssertTrue(t.token.hasPrefix("muse_pat_"))
        XCTAssertTrue(t.token.hasPrefix(t.prefix))
        XCTAssertNotNil(t.expiresAt)
        let listed = try await a.tokens()
        XCTAssertEqual(listed.map(\.id), [t.id])
        c = try await a.connections()
        XCTAssertEqual(c.claudeApp.tokens, 1)
        try await a.revokeToken(t.id)
        let none = try await a.tokens()
        XCTAssertTrue(none.isEmpty)
        do {
            _ = try await a.createToken(name: "  ", expiresDays: nil)
            XCTFail("empty")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
    }

    func testRelayEvent() async {
        let a = api()
        var it = a.events().makeAsyncIterator()
        _ = await it.next()
        a.setRelay(CameraRelayPresence(online: true, blender: false))
        let e = await it.next()
        XCTAssertEqual(e, .relay(CameraRelayPresence(online: true, blender: false)))
    }
}
