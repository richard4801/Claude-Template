import XCTest
@testable import MuseCore

/// Auto reframe that follows faces (the steps of Android's Reframe.kt): x keys centre the face, never show an edge,
/// ignore jitter inside the dead zone, hold through gaps, and a still face is a plain transform.x.
final class EditV2ReframeTests: XCTestCase {
    typealias E = EditV2

    /// A 16:9 1920×1080 clip on a 9:16 canvas (cover: 3.16 canvas widths wide), 4 s.
    private func wide() -> E.Project {
        E.Project(sourceTakeId: "t", canvas: E.Canvas(width: 1080, height: 1920, fps: 30),
                  assets: [E.Asset(id: "v", kind: .video, take: "t", durationSec: 10, width: 1920, height: 1080, hasAudio: true)],
                  tracks: [E.Track(id: "main", kind: .main, items: [.video(E.VideoClip(id: "c1", asset: "v", inSec: 0, outSec: 4))])])
    }
    private let cover = (1920.0 / 1080) / (1080.0 / 1920)
    private func frames(_ x: (Double) -> Double?) -> [E.FaceSample] { stride(from: 0.0, through: 4.0, by: 0.2).map { E.FaceSample(t: $0, x: x($0)) } }
    private func follow(_ s: [E.FaceSample]) -> E.FaceFollow? {
        let p = wide()
        return E.followFace(p.mainClips[0], asset: p.assets[0], canvasWidth: 1080, canvasHeight: 1920, samples: s)
    }

    func testFollowsAFaceMovingRight() throws {
        guard case .keys(let xs)? = follow(frames { 0.3 + 0.4 * $0 / 4 }) else { return XCTFail("keys") }
        XCTAssertEqual(xs.first?.t, 0)
        XCTAssertEqual(xs.last?.t, 4)
        XCTAssertLessThanOrEqual(xs.count, E.reframeMaxKeys)
        XCTAssertTrue(xs.allSatisfy { $0.ease == .easeInOut })
        // Face left of centre → picture shifted right (x > 0.5) at the start; it travels left (dead zone and EMA lag it).
        XCTAssertGreaterThan(xs.first!.v, 0.5)
        XCTAssertLessThan(xs.last!.v, xs.first!.v - 0.5)
        let lim = (cover - 1) / 2
        XCTAssertTrue(xs.allSatisfy { $0.v >= 0.5 - lim - 1e-4 && $0.v <= 0.5 + lim + 1e-4 })
    }

    func testJitterInsideTheDeadZoneIsStill() {
        // ±0.005 of the source is ±0.016 canvas widths: inside the 0.04 band.
        let f = follow(frames { t in 0.5 + (Int((t * 5).rounded()) % 2 == 0 ? 0.005 : -0.005) })
        guard case .still(let x)? = f else { return XCTFail("\(String(describing: f))") }
        XCTAssertEqual(x, 0.5 - 0.005 * cover, accuracy: 1e-3)
    }

    func testGapsHoldAndEdgesClamp() {
        // The face at the far left, then lost: the picture stays at its right limit.
        let f = follow(frames { $0 < 1 ? 0.0 : nil })
        guard case .still(let x)? = f else { return XCTFail("\(String(describing: f))") }
        XCTAssertEqual(x, 0.5 + (cover - 1) / 2, accuracy: 1e-4)
        XCTAssertNil(follow(frames { _ in nil }))
    }

    func testStateOpAndRefusals() {
        var s = EditSuiteState(wide())
        s.selection = "c1"
        XCTAssertFalse(s.followFaces(frames { _ in nil }))
        XCTAssertEqual(s.lastRefusal?.message, "No face found in this clip")
        XCTAssertTrue(s.followFaces(frames { 0.2 + 0.6 * $0 / 4 }))
        XCTAssertNotNil(s.selectedVideo?.keyframes?.x)
        XCTAssertNil(E.problem(s.project))
        // A still face: transform.x, the x keys gone.
        XCTAssertTrue(s.followFaces(frames { _ in 0.7 }))
        XCTAssertNil(s.selectedVideo?.keyframes?.x)
        XCTAssertEqual(s.selectedVideo?.transform?.x ?? 0, 0.5 - 0.2 * cover, accuracy: 1e-3)
        // A picture that already fits: nothing to move.
        var q = wide()
        q.canvas = E.Canvas(width: 1920, height: 1080, fps: 30)
        var t = EditSuiteState(q)
        t.selection = "c1"
        XCTAssertFalse(t.followFaces(frames { _ in 0.7 }))
    }
}
