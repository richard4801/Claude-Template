import XCTest
@testable import MuseCore

/// Editor contract wave 1 (mirror, freeze frame, blend modes, blur fill): the Swift port gives the reference's answers
/// (functions.json → wave1).
final class EditV2Wave1Tests: XCTestCase {
    typealias E = EditV2
    private var w: JV { (try? editorFixture("functions"))?["wave1"] ?? .null }

    func testBlendPixel() throws {
        let cases = w["blend"].array
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let mode = try XCTUnwrap(E.BlendMode(rawValue: c["mode"].string ?? ""))
            let top = c["top"].array.compactMap(\.double), below = c["below"].array.compactMap(\.double)
            let out = E.blendPixel(mode, top: top, below: below, a: c["a"].double ?? 1)
            let want = c["out"].array.compactMap(\.double)
            for i in 0..<3 { XCTAssertEqual(out[i], want[i], accuracy: 1e-6, "\(mode) \(top) over \(below)") }
        }
    }

    func testItemCornersWithFlips() throws {
        for c in w["corners"].array {
            let t = c["t"].isNull ? nil : try c["t"].decode(E.Transform.self)
            let fit = try c["fit"].decode(E.Fit.self)
            let got = E.itemCorners(canvasWidth: c["canvas"]["width"].double!, canvasHeight: c["canvas"]["height"].double!, w: c["w"].double!, h: c["h"].double!,
                                    fit: fit, transform: t)
            let want = c["corners"].array.map { $0.array.compactMap(\.double) }
            for (g, e) in zip(got, want) {
                XCTAssertEqual(g[0], e[0], accuracy: 1e-5, "\(c)")
                XCTAssertEqual(g[1], e[1], accuracy: 1e-5, "\(c)")
            }
        }
    }

    func testHoldTiming() throws {
        let h = w["hold"]
        let clip = try h["clip"].decode(E.VideoClip.self)
        XCTAssertEqual(E.clipLength(clip), h["length"].double!, accuracy: 1e-9)
        for s in h["sourceAt"].array { XCTAssertEqual(E.clipSourceAt(clip, s["t"].double!), s["src"].double!, accuracy: 1e-9) }
        XCTAssertEqual(E.clipTimeAt(clip, clip.inSec), h["timeAt"].double!, accuracy: 1e-9)
        let wave = try XCTUnwrap(editorFixture("projects").array.first { ($0["name"].string ?? "").hasPrefix("wave 1") })["project"].decode(E.Project.self)
        for c in h["cuts"].array {
            let cuts = try c["cuts"].decode([E.SecRange].self)
            let got = try JV.of(E.applyCuts(wave, assetId: "src", cuts: cuts))
            let d = jsonDiff(got, c["project"])
            XCTAssert(d.isEmpty, "applyCuts \(cuts): " + d.prefix(5).joined(separator: "; "))
        }
    }

    func testBlurFill() throws {
        let b = w["blurFill"]
        let out = E.blurFill(b["rgb"].array.compactMap(\.double), w: Int(b["w"].double!), h: Int(b["h"].double!), radius: Int(b["radius"].double!))
        let want = b["out"].array.compactMap(\.double)
        XCTAssertEqual(out.count, want.count)
        for (g, e) in zip(out, want) { XCTAssertEqual(g, e, accuracy: 1e-6) }
        XCTAssertEqual(E.blurFillDarken, b["darken"].double!)
        for r in b["radii"].array {
            XCTAssertEqual(E.blurFillRadius(width: Int(r["width"].double!), height: Int(r["height"].double!)), Int(r["radius"].double!))
        }
        let wave = try XCTUnwrap(editorFixture("projects").array.first { ($0["name"].string ?? "").hasPrefix("wave 1") })["project"].decode(E.Project.self)
        for c in b["clipAt"].array {
            let got = E.blurFillClip(wave, c["t"].double!)
            if c["at"].isNull { XCTAssertNil(got); continue }
            XCTAssertEqual(got?.clipId, c["at"]["clipId"].string, "t \(c["t"])")
            XCTAssertEqual(got?.local ?? -1, c["at"]["local"].double!, accuracy: 1e-6, "t \(c["t"])")
        }
    }
}
