import XCTest
@testable import MuseCore

/// Colour keyframes (contract, WS8 c10e398): adjustAt and the colour matrix at item-local t give the reference's answers
/// (functions.json → colorKeys).
final class EditV2ColorKeysTests: XCTestCase {
    typealias E = EditV2

    func testAdjustAtAndMatrix() throws {
        let cases = try editorFixture("functions")["colorKeys"].array
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let item = c["item"]
            let adjust = item["adjust"].isNull ? nil : try item["adjust"].decode(E.Adjust.self)
            let filter = item["filter"].isNull ? nil : try item["filter"].decode(E.FilterRef.self)
            let keys = try item["keyframes"].decode(E.Keyframes.self)
            XCTAssertTrue(E.hasColorKeys(keys))
            for s in c["samples"].array {
                let t = s["t"].double!
                let got = E.adjustAt(adjust, keys, t)
                if s["adjust"].isNull {
                    XCTAssertNil(got, "t \(t)")
                } else {
                    let want = try s["adjust"].decode(E.Adjust.self)
                    XCTAssertEqual(got, want, "t \(t)")
                }
                let m = E.colorMatrix(got, filter)
                let wm = s["matrix"].array.compactMap(\.double)
                XCTAssertEqual(m.count, wm.count)
                for (g, e) in zip(m, wm) { XCTAssertEqual(g, e, accuracy: 1e-5, "matrix at t \(t)") }
            }
        }
    }

    func testColorKeysOnTheSelectedClip() {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 6), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        s.selection = s.project.mainClips[0].id
        XCTAssertTrue(s.setVisualValue(.exposure, 0.4))
        XCTAssertEqual(s.project.mainClips[0].adjust?.exposure, 0.4, "unkeyed: the static value")
        s.playhead = 1; XCTAssertTrue(s.addKeyframe(.exposure, value: -0.5))
        s.playhead = 3; XCTAssertTrue(s.addKeyframe(.exposure, value: 0.5))
        s.playhead = 2
        XCTAssertEqual(s.visualValue(.exposure) ?? 9, 0, accuracy: 1e-6, "half-way between the keys")
        XCTAssertTrue(s.setVisualValue(.exposure, 0.2), "keyed: sets a key at the playhead")
        XCTAssertEqual(s.project.mainClips[0].keyframes?.exposure?.count, 3)
        XCTAssertNil(E.problem(s.project))
        XCTAssertFalse(s.setVisualValue(.volume, 1))
    }
}

/// The owner's model pick on Edit helpers (WS13 engineModel): the purpose each helper runs, and the field on the wire.
final class EditorHelperModelTests: XCTestCase {
    func testPurposesAndEncoding() throws {
        XCTAssertEqual(EditorJobKind.captions.enginePurpose(nil), .captions)
        XCTAssertEqual(EditorJobKind.cuts.enginePurpose(nil), .captions)
        XCTAssertEqual(EditorJobKind.matte.enginePurpose(nil), .matte)
        XCTAssertEqual(EditorJobKind.matte.enginePurpose(EditorJobOptions(points: [])), .track)
        XCTAssertEqual(EditorJobKind.denoise.enginePurpose(nil), .denoise)
        XCTAssertNil(EditorJobKind.beats.enginePurpose(nil))
        let src = EditorSource(takeId: "tk", durationSec: 3)
        let plain = String(decoding: try JSONEncoder().encode(EditorJobRequest(kind: .denoise, source: src)), as: UTF8.self)
        XCTAssertFalse(plain.contains("engineModel"), "no pick: the studio's default, field left out")
        let picked = String(decoding: try JSONEncoder().encode(EditorJobRequest(kind: .denoise, source: src, engineModel: "m1")), as: UTF8.self)
        XCTAssertTrue(picked.contains("\"engineModel\":\"m1\""))
    }
}
