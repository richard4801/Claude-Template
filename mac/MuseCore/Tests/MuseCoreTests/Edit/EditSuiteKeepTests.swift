import XCTest
@testable import MuseCore

/// Remove background (2026-11-08): the alpha matte on a clip, and "Pick what to keep" (tap to keep).
final class EditSuiteKeepTests: XCTestCase {
    typealias E = EditV2

    private func project() -> E.Project {
        E.fromV1(EditList(sourceTakeId: "t1", sourceDurationSec: 10), E.SourceFacts(width: 1080, height: 1920, fps: 30))
    }

    func testTapAddsKeepsLeavesOutAndRemoves() {
        var k = EditSuite.KeepPick(clipId: "c1", assetId: "src", sourceSec: 2.5)
        XCTAssertFalse(k.canRun)
        XCTAssertEqual(k.summary, "Tap what to keep")
        XCTAssertTrue(k.tap(x: 0.5, y: 0.4, aspect: 9.0 / 16))
        XCTAssertEqual(k.points, [KeepPoint(x: 0.5, y: 0.4, t: 2.5, keep: nil)])
        k.leaveOut = true
        k.tap(x: 0.1, y: 0.9, aspect: 9.0 / 16)
        XCTAssertEqual(k.points.last?.keep, false)
        XCTAssertEqual(k.summary, "1 kept · 1 left out")
        XCTAssertTrue(k.canRun)
        // A tap on a point removes it (whatever the mode).
        k.confirming = true
        XCTAssertTrue(k.tap(x: 0.51, y: 0.41, aspect: 9.0 / 16))
        XCTAssertFalse(k.confirming)
        XCTAssertEqual(k.keepCount, 0)
        XCTAssertFalse(k.canRun)
        XCTAssertEqual(k.options.points?.count, 1)
        // Clamped to the frame, at most 10, and nothing for NaN.
        k.clear()
        XCTAssertFalse(k.tap(x: .nan, y: 0.5))
        k.leaveOut = false
        for i in 0..<12 { k.tap(x: Double(i) / 11, y: 1.4) }
        XCTAssertEqual(k.points.count, EditSuite.maxKeepPoints)
        XCTAssertTrue(k.points.allSatisfy { $0.y == 1 && (0...1).contains($0.x) })
    }

    func testKeepPointChecks() {
        XCTAssertNil(EditSuite.keepPointsProblem([KeepPoint(x: 0.5, y: 0.5, t: 1)], sourceSec: 3))
        XCTAssertNotNil(EditSuite.keepPointsProblem([], sourceSec: 3))
        XCTAssertNotNil(EditSuite.keepPointsProblem([KeepPoint(x: 0.5, y: 0.5, keep: false)], sourceSec: 3))
        XCTAssertNotNil(EditSuite.keepPointsProblem([KeepPoint(x: 1.2, y: 0.5)], sourceSec: 3))
        XCTAssertNotNil(EditSuite.keepPointsProblem([KeepPoint(x: 0.5, y: 0.5, t: 9)], sourceSec: 3))
        XCTAssertNotNil(EditSuite.keepPointsProblem(Array(repeating: KeepPoint(x: 0.5, y: 0.5), count: 11), sourceSec: 3))
    }

    func testAlphaMatteValidatesAndRoundTrips() throws {
        var p = project()
        p = p.addingAsset(E.Asset(id: "bg2", kind: .video, upload: "up_1", durationSec: 10))
        p = try XCTUnwrap(p.updating("c1") { it in
            guard case .video(var v) = it else { return }
            v.alphaMatte = E.AlphaMatte(asset: "bg2")
            it = .video(v)
        })
        XCTAssertNoThrow(try E.validate(p))
        let back = try JSONDecoder().decode(E.Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.mainClips.first?.alphaMatte, E.AlphaMatte(asset: "bg2"))
        XCTAssertNil(E.toV1(p), "a matted clip isn't a v1 edit")
        // The matte must be a video asset of the project.
        var bad = p
        bad = try XCTUnwrap(bad.updating("c1") { it in
            guard case .video(var v) = it else { return }
            v.alphaMatte = E.AlphaMatte(asset: "nope")
            it = .video(v)
        })
        XCTAssertThrowsError(try E.validate(bad))
    }

    func testServerMatteResultDecodes() throws {
        let json = #"{"asset":{"kind":"video","upload":"up_9","durationSec":6},"alpha":true,"mode":"tracked","points":[{"x":0.4,"y":0.3,"t":1.2,"keep":true},{"x":0.9,"y":0.9,"keep":false}]}"#
        let r = try JSONDecoder().decode(EditorJobResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.alpha, true)
        XCTAssertEqual(r.mode, "tracked")
        XCTAssertEqual(r.points?.map(\.keeps), [true, false])
        XCTAssertNil(r.chroma)
        let opts = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditorJobOptions(points: [KeepPoint(x: 0.5, y: 0.5, t: 2)]))) as? [String: Any]
        XCTAssertEqual((opts?["points"] as? [[String: Any]])?.first?["t"] as? Double, 2)
    }

    func testFeaturesSayWhenBackgroundRemovalIsComingSoon() throws {
        let off = try JSONDecoder().decode(EditorFeatures.self, from: Data(#"{"captions":{"available":true},"matte":{"available":false,"maxSec":120},"maxSourceSec":600}"#.utf8))
        XCTAssertFalse(off.matteAvailable)
        let on = try JSONDecoder().decode(EditorFeatures.self, from: Data(#"{"matte":{"available":true,"maxSec":120}}"#.utf8))
        XCTAssertTrue(on.matteAvailable)
        XCTAssertTrue(try JSONDecoder().decode(EditorFeatures.self, from: Data("{}".utf8)).matteAvailable, "an older server: offer it")
    }

    func testSourceTimeThroughPieces() {
        // 4 s of source played as 2 s at 2× then 2 s at 1×: [0, 4) at 2× = 2 s, [4, 6) at 1× = 2 s.
        let seg = E.VideoSegment(trackId: "main", itemId: "c1", assetId: "src", lane: 0, mainIndex: 0, layer: 0, timelineStart: 10, timelineEnd: 14,
                                 sourceStart: 0, sourceEnd: 6, pieces: [E.Piece(inSec: 0, outSec: 4, speed: 2), E.Piece(inSec: 4, outSec: 6, speed: 1)])
        XCTAssertEqual(E.sourceTime(seg, at: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(E.sourceTime(seg, at: 11), 2, accuracy: 1e-9)
        XCTAssertEqual(E.sourceTime(seg, at: 13), 5, accuracy: 1e-9)
        XCTAssertEqual(E.sourceTime(seg, at: 99), 6, accuracy: 1e-9)
        XCTAssertEqual(E.sourceTime(seg, at: 0), 0, accuracy: 1e-9)
    }
}
