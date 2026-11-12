import XCTest
@testable import MuseCore

/// Layers (plans/layers-edit.md, Phase 1) against the shared fixture layers.json (server/api/scripts/editor-fixtures.ts):
/// validation, the layer and background clips, recolour, boxes over time, text behind and pinned text.
final class EditV2LayersTests: XCTestCase {
    typealias E = EditV2

    private func fx() throws -> JV { try editorFixture("layers") }

    func testProjectRoundTripsAndValidation() throws {
        let f = try fx()
        let p = try f["project"].decode(E.Project.self)
        let diff = jsonDiff(try JV.of(p), f["project"]); XCTAssert(diff.isEmpty, diff.prefix(4).joined(separator: "; "))
        let cases = f["validation"].array
        XCTAssertGreaterThan(cases.count, 15)
        for c in cases {
            let name = c["name"].string ?? "?"
            guard let q = try? c["project"].decode(E.Project.self) else {
                XCTAssertNotEqual(c["ok"], .bool(true), "\(name): a valid project didn't decode")
                continue
            }
            let problem = E.problem(q, presets: E.filters)
            if c["ok"] == .bool(true) { XCTAssertNil(problem, "\(name): \(problem?.description ?? "")") }
            else { XCTAssertEqual(problem?.field, c["field"].string, "\(name): \(problem?.description ?? "no problem")") }
        }
    }

    func testLayerAndBaseClips() throws {
        let f = try fx()
        for c in f["layerClip"].array {
            let got = E.layerClip(try c["clip"].decode(E.VideoClip.self), try c["layer"].decode(E.ClipLayer.self))
            let d = jsonDiff(try JV.of(got), c["out"]); XCTAssert(d.isEmpty, "layerClip: " + d.prefix(4).joined(separator: "; "))
        }
        for c in f["baseClip"].array {
            let got = E.baseClip(try c["clip"].decode(E.VideoClip.self))
            let d = jsonDiff(try JV.of(got), c["out"]); XCTAssert(d.isEmpty, "baseClip: " + d.prefix(4).joined(separator: "; "))
        }
    }

    func testHelpersDropLayers() throws {
        let f = try fx()
        let p = try f["project"].decode(E.Project.self)
        let c1 = p.mainClips[0]
        XCTAssertNil(E.reverseClip(c1, reversed: "rev", durationSec: 10)?.layers)
        XCTAssertNil(E.deriveClip(c1, copy: "st", op: .stabilize).layers)
        var q = p
        q.assets.append(try JV.obj(["id": .str("sm"), "kind": .str("video"), "upload": .str("up_sm"), "durationSec": .num(2),
                                    "derivedFrom": .obj(["asset": .str("src"), "op": .str("slowmo"), "startSec": .num(2), "endSec": .num(3), "factor": .num(2)])]).decode(E.Asset.self))
        let r = try XCTUnwrap(E.applySlowmo(q, clipId: "c1", slowId: "sm"))
        let got = r.project.mainClips.map { JV.obj(["id": .str($0.id), "layers": .num(Double($0.layers?.count ?? 0))]) }
        let d = jsonDiff(.arr(got), f["dropped"]["slowmo"]); XCTAssert(d.isEmpty, d.joined(separator: "; "))
    }

    func testRecolorBoxesAndBlur() throws {
        let f = try fx()
        for c in f["recolor"].array {
            let rgb = c["rgb"].array.compactMap(\.double)
            let got = E.recolorPixel((rgb[0], rgb[1], rgb[2]), try c["recolor"].decode(E.Recolor.self))
            let want = c["out"].array.compactMap(\.double)
            XCTAssertEqual(got.0, want[0], accuracy: 1e-6); XCTAssertEqual(got.1, want[1], accuracy: 1e-6); XCTAssertEqual(got.2, want[2], accuracy: 1e-6)
        }
        let p = try f["project"].decode(E.Project.self)
        let track = p.mainClips[0].layers?[0].track
        for c in f["boxAt"].array {
            let t = try XCTUnwrap(c["t"].double)
            assertJSON(E.layerBoxAt(track, t), c["box"], "boxAt \(t)")
        }
        for c in f["blurPx"].array {
            let w = try XCTUnwrap(c["canvas"]["width"].double), h = try XCTUnwrap(c["canvas"]["height"].double), v = c["v"].double
            XCTAssertEqual(E.layerBlurPx(width: w, height: h, v), try XCTUnwrap(c["blur"].double), accuracy: 1e-6)
            XCTAssertEqual(E.layerFeatherPx(width: w, height: h, v), try XCTUnwrap(c["feather"].double), accuracy: 1e-6)
        }
    }

    func testTextBehindAndPins() throws {
        let f = try fx()
        let p = try f["project"].decode(E.Project.self)
        for c in f["steady"].array {
            let i = Int(try XCTUnwrap(c["index"].double))
            assertJSON(E.clipSteadyRange(p, i), c["range"], "steady \(i)")
        }
        for c in f["aboveTextAt"].array {
            let t = try XCTUnwrap(c["t"].double)
            assertJSON(E.aboveTextLayersAt(p, t), c["layers"], "aboveText \(t)")
        }
        for c in f["pinPoint"].array {
            let t = try XCTUnwrap(c["t"].double), pin = try c["pin"].decode(E.TextPin.self)
            let got = E.pinPoint(p, pin, t).map { JV.obj(["x": .num($0.x), "y": .num($0.y)]) } ?? .null
            let d = jsonDiff(got, c["point"]); XCTAssert(d.isEmpty, "pin \(t) \(pin.anchor): " + d.joined(separator: "; "))
        }
    }
}
