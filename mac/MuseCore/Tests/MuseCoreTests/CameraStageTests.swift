import Foundation
import XCTest
@testable import MuseCore

/// Camera stage viewer: paths projected through the shot camera, the timeline ↔ player sync, set.json.
final class CameraStageTests: XCTestCase {
    private func pose(_ focal: Double = 36) -> CameraPose { CameraPose(position: Vec3(0, -4, 1.5), target: Vec3(0, 0, 1.5), focalMm: focal) }

    func testProjectionMatchesBlenderPinhole() throws {
        // 36 mm lens on a 36 mm sensor: focal = 1 longer side. 9:16 frame: the longer side is the height.
        let cam = try XCTUnwrap(ShotCameraProjection(pose(), aspect: 9.0 / 16))
        let centre = try XCTUnwrap(cam.project(Vec3(0, 0, 1.5)))
        XCTAssertEqual(centre.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 0.5, accuracy: 1e-9)
        // 1 m right at 4 m: 0.25 of the height = 0.25·16/9 of the width.
        let right = try XCTUnwrap(cam.project(Vec3(1, 0, 1.5)))
        XCTAssertEqual(right.x, 0.5 + 0.25 * 16 / 9, accuracy: 1e-9)
        XCTAssertEqual(right.y, 0.5, accuracy: 1e-9)
        // 1 m up: higher on screen (smaller y).
        let up = try XCTUnwrap(cam.project(Vec3(0, 0, 2.5)))
        XCTAssertEqual(up.y, 0.25, accuracy: 1e-9)
        // Landscape 16:9: the longer side is the width.
        let wide = try XCTUnwrap(ShotCameraProjection(pose(), aspect: 16.0 / 9))
        XCTAssertEqual(try XCTUnwrap(wide.project(Vec3(1, 0, 1.5))).x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(wide.project(Vec3(0, 0, 2.5))).y, 0.5 - 0.25 * 16 / 9, accuracy: 1e-9)
        // Behind the camera: not drawn. A camera on its own target: no projection.
        XCTAssertNil(cam.project(Vec3(0, -5, 1.5)))
        XCTAssertNil(ShotCameraProjection(CameraPose(position: Vec3(1, 1, 1), target: Vec3(1, 1, 1), focalMm: 35), aspect: 1))
    }

    func testPolylineClipsBehindTheCamera() throws {
        let cam = try XCTUnwrap(ShotCameraProjection(pose(), aspect: 1))
        // From behind the camera to in front: one run, starting at the near plane.
        XCTAssertEqual(cam.project(polyline: [Vec3(0.2, -6, 0), Vec3(0.2, 0, 0)]).count, 1)
        // In front → behind → in front: two runs.
        let runs = cam.project(polyline: [Vec3(-1, 0, 0), Vec3(0, -8, 0), Vec3(1, 0, 0)])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(try XCTUnwrap(runs.first?.first).x, cam.project(Vec3(-1, 0, 0))!.x, accuracy: 1e-9)
        // Wholly behind: nothing.
        XCTAssertTrue(cam.project(polyline: [Vec3(0, -6, 0), Vec3(1, -7, 0)]).isEmpty)
    }

    func testOverlayFollowsThePlayhead() throws {
        var s = FakeCameraAPI.seedSession(now: 0, relay: nil)
        let track = try XCTUnwrap(s.blocking?.characters.first)
        let a = try XCTUnwrap(CameraStageMath.overlay(s, at: 0))
        let b = try XCTUnwrap(CameraStageMath.overlay(s, at: s.durationSec))
        XCTAssertEqual(a.characters.count, s.blocking?.characters.filter { !$0.keyframes.isEmpty }.count)
        XCTAssertFalse(a.characters[0].path.isEmpty)
        // The dot moves along her path.
        if let p = a.characters.first(where: { $0.modelId == track.modelId })?.now, let q = b.characters.first(where: { $0.modelId == track.modelId })?.now,
           track.keyframes.first?.position != track.keyframes.last?.position {
            XCTAssertNotEqual(p, q)
        }
        s.cameraPath = nil
        XCTAssertNil(CameraStageMath.overlay(s, at: 0))
        XCTAssertEqual(CameraStageMath.aspect("16:9"), 16.0 / 9)
        XCTAssertEqual(CameraStageMath.aspect("nonsense"), 9.0 / 16)
        XCTAssertEqual(CameraStageMath.sampleTimes(duration: 1, keys: [0.25], perSecond: 2), [0, 0.25, 0.5, 1])
    }

    func testTimelineAndPlayerStayInStep() {
        // The player's own time echoing back into the playhead doesn't seek; a scrub does.
        XCTAssertFalse(StagePlayback.needsSeek(playerTime: 2.0, playhead: 2.01, fps: 24))
        XCTAssertTrue(StagePlayback.needsSeek(playerTime: 2.0, playhead: 2.5, fps: 24))
        XCTAssertEqual(StagePlayback.playhead(fromPlayer: 6.04, duration: 6), 6)
        XCTAssertEqual(StagePlayback.playhead(fromPlayer: .nan, duration: 6), 0)
        XCTAssertEqual(StagePlayback.playhead(fromPlayer: 2.5, duration: 6), 2.5)
        // Play at the end starts over.
        XCTAssertEqual(StagePlayback.startTime(playhead: 6, duration: 6, fps: 24), 0)
        XCTAssertEqual(StagePlayback.startTime(playhead: 2, duration: 6, fps: 24), 2)
        // No video: the clock plays the plan, looping or stopping at END.
        XCTAssertEqual(StagePlayback.advance(5.9, by: 0.2, duration: 6, loop: true).time, 0.1, accuracy: 1e-9)
        XCTAssertTrue(StagePlayback.advance(5.9, by: 0.2, duration: 6, loop: true).playing)
        XCTAssertEqual(StagePlayback.advance(5.9, by: 0.2, duration: 6, loop: false).time, 6)
        XCTAssertFalse(StagePlayback.advance(5.9, by: 0.2, duration: 6, loop: false).playing)
        // Frame steps.
        XCTAssertEqual(StagePlayback.step(1.0, frames: 1, fps: 24, duration: 6), 25.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(StagePlayback.step(0, frames: -1, fps: 24, duration: 6), 0)
        XCTAssertEqual(StagePlayback.timeLabel(1.25, duration: 6), "1.2 / 6.0 s")
    }

    func testSetFile() throws {
        let json = #"{"version":1,"objects":[{"name":"MUSE_prop_table","shape":"box","size":[1,0.6,0.75],"position":[0,1,0],"rotationDeg":[0,0,30]},{"name":"bad","shape":"box","size":[0,0,0],"position":[0,0,0]}]}"#
        let f = try XCTUnwrap(CameraSetFile.parse(Data(json.utf8)))
        XCTAssertEqual(f.objects.map(\.name), ["MUSE_prop_table"])
        XCTAssertEqual(f.objects[0].rotationDeg, Vec3(0, 0, 30))
        XCTAssertNil(CameraSetFile.parse(Data("nope".utf8)))
        XCTAssertEqual(BlenderAssetKinds.kind(forFile: "set.json"), "set_json")
        XCTAssertEqual(CameraGuides.label("set_json"), "set.json")
        let s = FakeCameraAPI.seedSession(now: 0, relay: nil)
        let frame = OrbitFraming.of(s, set: f)
        XCTAssertLessThan(frame.eye.y, frame.target.y) // from the camera's side
        XCTAssertGreaterThan(frame.eye.z, frame.target.z)
    }

    func testGreyboxRenderAlsoWritesTheSet() throws {
        let d = try BlenderArgs.data(.renderGuides, JSONDecoder().decode(JSONValue.self, from: Data(#"{"passes":["greybox"]}"#.utf8)), outDir: "/Users/a/MUSE/CameraSessions/cs_abc123/out")
        XCTAssertEqual(d["passes"], .array([.string("greybox"), .string("set_json")]))
        let k = try BlenderArgs.data(.renderGuides, JSONDecoder().decode(JSONValue.self, from: Data(#"{"passes":["keyframes"]}"#.utf8)), outDir: "/Users/a/MUSE/CameraSessions/cs_abc123/out")
        XCTAssertEqual(k["passes"], .array([.string("keyframes")]))
        let code = try XCTUnwrap(BlenderScripts.code(.renderGuides, data: d))
        XCTAssertTrue(code.contains("set.json"))
    }
}
