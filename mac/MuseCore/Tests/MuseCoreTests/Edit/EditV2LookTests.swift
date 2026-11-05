import Foundation
import XCTest
@testable import MuseCore

/// The Swift port of the looks reference (server/api/src/editor/look.ts) against the shared fixture looks.json, the
/// bundled pack in server/api/assets/lookpack/looks, and the tables the Core Image renderer bakes.
final class EditV2LookTests: XCTestCase {
    typealias E = EditV2

    /// The repository root (this file is mac/MuseCore/Tests/MuseCoreTests/Edit/…).
    static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { u.deleteLastPathComponent() }
        return u
    }()
    static let packDir = repo.appendingPathComponent("server/api/assets/lookpack/looks")

    func fixture() throws -> JV { try editorFixture("looks") }
    func luts(_ f: JV) throws -> [String: E.Lut] {
        let test5 = try E.parseCube(try XCTUnwrap(f["cubes"]["test5"].string))
        let gold = try E.parseCube(String(contentsOf: Self.packDir.appendingPathComponent("film-gold.cube"), encoding: .utf8))
        return ["test5": test5, "pack:film-gold": gold]
    }
    func nums(_ v: JV) -> [Double] { v.array.compactMap(\.double) }
    func maxDiff(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (0..<3).map { abs(a[$0] - b[$0]) }.max()! }

    func testRendersMatchTheReference() throws {
        let f = try fixture()
        let img = f["image"]
        let pic = E.LookImage(width: Int(img["width"].double!), height: Int(img["height"].double!), data: nums(img["data"]).map(Float.init))
        XCTAssertEqual(pic.data.count, 24 * 16 * 3)
        let L = try luts(f)
        let renders = f["renders"].array
        XCTAssertEqual(renders.count, 10)
        for r in renders {
            let name = r["name"].string ?? "?"
            let look = try r["look"].decode(E.Look.self)
            let matrix = r["matrix"].isNull ? nil : nums(r["matrix"])
            let lut = r["lut"].string.flatMap { L[$0] }
            if !r["lut"].isNull { XCTAssertNotNil(lut, name) }
            let out = E.renderLook(pic, look, matrix: matrix, lut: lut, frame: Int(r["frame"].double ?? 0), fps: 30)
            let want = nums(r["out"])
            XCTAssertEqual(out.data.count, want.count, name)
            var worst = 0.0, at = 0
            for (i, (a, b)) in zip(out.data, want).enumerated() where abs(Double(a) - b) > worst { worst = abs(Double(a) - b); at = i }
            XCTAssertLessThanOrEqual(worst, 1e-3, "\(name): value \(at) is \(out.data[at]), reference \(want[at])")
        }
    }

    func testLutSamples() throws {
        let f = try fixture()
        let L = try luts(f)
        let cases = f["lutSamples"].array
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            let lut = try XCTUnwrap(L[c["lut"].string ?? ""])
            let rgb = nums(c["rgb"]), want = nums(c["out"])
            let o = E.lutSample(lut, rgb[0], rgb[1], rgb[2])
            for k in 0..<3 { XCTAssertEqual(o[k], want[k], accuracy: 1e-4, "\(c)") }
        }
    }

    func testCurves() throws {
        for c in try fixture()["curves"].array {
            let pts = try c["points"].decode(E.CurvePoints.self)
            let fn = try XCTUnwrap(E.curveFn(pts))
            for s in c["samples"].array {
                let xy = nums(s)
                XCTAssertEqual(fn(xy[0]), xy[1], accuracy: 1e-4, "\(pts) at \(xy[0])")
            }
        }
        XCTAssertNil(E.curveFn([[0, 0]]))
        XCTAssertNil(E.curvesFn(E.Curves()))
    }

    func testHashIsBitExact() throws {
        let cases = try fixture()["hash"].array
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let v = E.hash01(Int(c["x"].double!), Int(c["y"].double!), Int(c["frame"].double!))
            XCTAssertEqual(v, c["v"].double!, accuracy: 1e-12, "\(c)")
        }
    }

    func testVignetteAndLeak() throws {
        let f = try fixture()
        for c in f["vignette"].array {
            let v = try c["vignette"].decode(E.Vignette.self)
            for s in c["samples"].array {
                let a = nums(s)
                XCTAssertEqual(E.vignetteMask(v, a[0], a[1]), a[2], accuracy: 1e-4, "\(c["vignette"]) at \(a)")
            }
        }
        for c in f["leak"].array {
            let l = try c["leak"].decode(E.Leak.self)
            for s in c["samples"].array {
                let o = E.leakColor(l, s["u"].double!, s["v"].double!, s["t"].double!), want = nums(s["out"])
                for k in 0..<3 { XCTAssertEqual(o[k], want[k], accuracy: 1e-4, "\(l.kind) \(s)") }
            }
        }
    }

    func testRadii() throws {
        let r = try fixture()["radii"].array
        XCTAssertEqual(r.count, 3)
        let halations = [E.Halation(amount: 1, radius: 0.3), E.Halation(amount: 1), E.Halation(amount: 1, radius: 1)]
        let grains = [E.Grain(amount: 1, size: 1), E.Grain(amount: 1, size: 2), E.Grain(amount: 1)]
        for (i, c) in r.enumerated() {
            let short = Int(c["short"].double!)
            XCTAssertEqual(E.sharpenRadius(short), Int(c["sharpen"].double!), "sharpen \(short)")
            XCTAssertEqual(E.halationRadius(short, halations[i]), Int(c["halation"].double!), "halation \(short)")
            XCTAssertEqual(E.grainCell(short, grains[i]), Int(c["grain"].double!), "grain \(short)")
        }
    }

    func testCubeParsing() throws {
        let f = try fixture()
        let bad = f["badCubes"].array
        XCTAssertEqual(bad.count, 6)
        for b in bad {
            XCTAssertThrowsError(try E.parseCube(b["text"].string!), b["name"].string ?? "?") { e in
                XCTAssert(e is E.CubeError, "\(e)")
            }
        }
        let good = f["goodCube"]
        let lut = try E.parseCube(good["text"].string!)
        XCTAssertEqual(lut.size, Int(good["size"].double!))
        XCTAssertEqual(lut.title, good["title"].string)
        XCTAssertEqual(lut.data.count, 2 * 2 * 2 * 3)
        // CRLF line ends, LUT_3D_INPUT_RANGE and a bad line's number.
        let crlf = try E.parseCube("LUT_3D_SIZE 2\r\nLUT_3D_INPUT_RANGE 0 2\r\n" + String(repeating: "0.5 0.5 0.5\r\n", count: 8))
        XCTAssertEqual(crlf.domainMax, [2, 2, 2])
        XCTAssertThrowsError(try E.parseCube("TITLE \"x\"\nLUT_3D_SIZE 2\n0 0 0\n0 0 x\n")) { e in
            XCTAssertEqual((e as? E.CubeError)?.message, "line 4: expected three numbers")
        }
    }

    func testThePackHas32LooksThatParseAtSize17() throws {
        let f = try fixture()
        XCTAssertEqual(f["pack"]["ids"].array.compactMap(\.string), E.lookPackIds)
        XCTAssertEqual(f["pack"]["cubeSize"].double, 17)
        let pack = try E.LookPack.load(directory: Self.packDir)
        XCTAssertEqual(pack.looks.count, 32)
        XCTAssertEqual(pack.cubeSize, 17)
        XCTAssertEqual(pack.ids, E.lookPackIds)
        XCTAssertEqual(Set(pack.looks.map(\.category)), Set(E.LookPack.categories))
        for e in pack.looks {
            XCTAssertEqual(e.look.lut, "pack:\(e.id)")
            XCTAssertEqual(e.look.packId, e.id)
            XCTAssertEqual(e.look.strength, 1)
            XCTAssertNil(E.lookProblem(e.look, assetKinds: [:], packIds: Set(E.lookPackIds)), e.id)
            let lut = try pack.lut(e.id, in: Self.packDir)
            XCTAssertEqual(lut.size, 17, e.id)
        }
        // packLook = the look the reference's packLook gives (the film-gold render uses it).
        let gold = try f["renders"].array.first { $0["name"].string == "pack look film-gold" }.map { try $0["look"].decode(E.Look.self) }
        XCTAssertEqual(E.packLook("film-gold", pack: pack), gold)
        XCTAssertNil(pack.packLook("nope"))
        // looks.json survives a round trip.
        let raw = try JSONDecoder().decode(JV.self, from: Data(contentsOf: Self.packDir.appendingPathComponent("looks.json")))
        XCTAssert(jsonStrictDiff(try JV.of(pack), raw).isEmpty)
    }

    func testProjectsWithLooksRoundTrip() throws {
        let cases = try editorFixture("validation").array.filter { $0["ok"] == .bool(true) && "\($0["project"])".contains("\"look\"") }
        XCTAssertGreaterThanOrEqual(cases.count, 2)
        for c in cases {
            let p = try c["project"].decode(E.Project.self)
            let d = jsonStrictDiff(try JV.of(p), c["project"])
            XCTAssert(d.isEmpty, "\(c["name"]): " + d.prefix(5).joined(separator: "; "))
            XCTAssertEqual(try E.Project.decode(p.encoded()), p)
        }
        // A full look survives too, and absent parts stay absent.
        let look = E.Look(lut: "pack:film-cine", strength: 0.7, curves: E.Curves(rgb: [[0, 0.05], [1, 0.95]], b: [[0, 0], [1, 0.9]]), lift: 0.2,
                          sharpen: 0.3, chromatic: 0.1, halation: E.Halation(amount: 0.2, threshold: 0.8), leak: E.Leak(kind: .teal, amount: 0.3),
                          vignette: E.Vignette(amount: -0.2), grain: E.Grain(amount: 0.4, size: 2))
        let j = try JV.of(look)
        XCTAssertEqual(try j.decode(E.Look.self), look)
        XCTAssert(j["halation"]["radius"].isNull && j["curves"]["r"].isNull)
        XCTAssertEqual(j.object.count, 10)
        XCTAssertEqual(try JV.of(E.Look()).object.count, 0)
    }

    func testUnknownKeysAreKeptForValidationOnly() throws {
        let l = try JSONDecoder().decode(E.Look.self, from: Data(#"{"bloom":1,"curves":{"rgb":[[0,0],[1,1]],"x":[[0,0],[1,1]]},"leak":{"kind":"green","amount":0.2}}"#.utf8))
        XCTAssertEqual(l.unknownKeys, ["bloom"])
        XCTAssertEqual(l.leak?.kind.isKnown, false)
        XCTAssertEqual(E.lookProblem(l, assetKinds: [:], packIds: [])?.field, "curves.x")
        XCTAssertEqual(try JV.of(l)["bloom"], .null)
        var m = l
        m.curves = nil
        XCTAssertEqual(E.lookProblem(m, assetKinds: [:], packIds: [])?.field, "leak.kind")
        m.leak = nil
        XCTAssertEqual(E.lookProblem(m, assetKinds: [:], packIds: [])?.field, "bloom")
        XCTAssertEqual(E.lookProblem(E.Look(lut: "cube1"), assetKinds: ["cube1": .lut], packIds: [])?.field, nil)
        XCTAssertEqual(E.lookProblem(E.Look(lut: "pack:anything"), assetKinds: [:], packIds: [])?.field, nil)
        XCTAssertEqual(E.lookProblem(E.Look(curves: E.Curves(g: [[0, 0]])), assetKinds: [:], packIds: [])?.field, "curves.g")
        XCTAssertEqual(E.lookProblem(E.Look(vignette: E.Vignette(amount: 0.5, softness: 2)), assetKinds: [:], packIds: [])?.field, "vignette.softness")
    }

    // MARK: GPU tables

    /// Trilinear lookup in an RGBA cube (red fastest), as Core Image samples a colour cube.
    func sampleCube(_ c: [Float], _ size: Int, _ v: SIMD3<Double>) -> SIMD3<Double> {
        var rgb: [Float] = []
        rgb.reserveCapacity(c.count / 4 * 3)
        for i in stride(from: 0, to: c.count, by: 4) { rgb.append(c[i]); rgb.append(c[i + 1]); rgb.append(c[i + 2]) }
        let lut = E.Lut(size: size, title: nil, domainMin: [0, 0, 0], domainMax: [1, 1, 1], data: rgb)
        return E.lutSample(lut, v.x, v.y, v.z)
    }

    func testLookCubeMatchesTheColourSteps() throws {
        let f = try fixture()
        let L = try luts(f)
        let matrix = nums(f["matrix"])
        let look = E.Look(lut: "pack:film-gold", strength: 0.8, curves: E.Curves(rgb: [[0, 0], [0.5, 0.55], [1, 1]]), lift: 0.3)
        let cube = E.lookCube(matrix: matrix, look: look, lut: L["pack:film-gold"], size: 33)
        XCTAssertEqual(cube.count, 33 * 33 * 33 * 4)
        let curves = E.curvesFn(look.curves)
        var worst = 0.0
        let data = nums(f["image"]["data"])
        for i in stride(from: 0, to: data.count, by: 3) {
            let v = SIMD3(data[i], data[i + 1], data[i + 2])
            let want = E.lookColor(v, matrix: matrix, curves: curves, lut: L["pack:film-gold"], strength: 0.8, lift: 0.036)
            let got = sampleCube(cube, 33, v)
            worst = max(worst, maxDiff(got, want))
        }
        XCTAssertLessThan(worst, 3.0 / 255, "the 33³ cube is within a few 1/255 of the exact colour steps")
        XCTAssert(E.lookColorIsIdentity(matrix: nil, look: E.Look(sharpen: 0.4), lut: nil))
        XCTAssertFalse(E.lookColorIsIdentity(matrix: nil, look: E.Look(lift: 0.4), lut: nil))
        XCTAssertFalse(E.lookColorIsIdentity(matrix: matrix, look: nil, lut: nil))
    }

    func testGrainCubesBlendToTheGrainFormula() {
        let (dk, lt) = E.grainCubes(amount: 0.7, size: 17)
        for v in [SIMD3(0.5, 0.5, 0.5), SIMD3(0.2, 0.6, 0.9), SIMD3(0.75, 0.3, 0.4)] {
            let l = (SIMD3(0.2126, 0.7152, 0.0722) * v).sum()
            for n in [0.0, 0.3, 1.0] {
                let want = v + SIMD3(repeating: 0.18 * 0.7 * (n - 0.5) * (1 - abs(2 * l - 1) * 0.5))
                let got = sampleCube(dk, 17, v) * (1 - n) + sampleCube(lt, 17, v) * n
                XCTAssertLessThan(maxDiff(got, want), 2e-3, "\(v) n \(n)")
            }
        }
    }

    func testMapsAndHalationMatrix() {
        let v = E.Vignette(amount: 0.6, size: 0.3)
        let map = E.vignetteMap(v, width: 8, height: 4)
        XCTAssertEqual(map.count, 8 * 4 * 4)
        XCTAssertEqual(Double(map[(1 * 8 + 2) * 4]), 1 - 0.6 * E.vignetteMask(v, 2.5 / 8, 1.5 / 4), accuracy: 1e-6)
        let light = E.vignetteMap(E.Vignette(amount: -0.5), width: 4, height: 4)
        XCTAssertEqual(Double(light[0]), 0.5 * E.vignetteMask(E.Vignette(amount: -0.5), 0.125, 0.125), accuracy: 1e-6)
        let lk = E.Leak(kind: .rose, amount: 0.7, angle: 140)
        let lm = E.leakMap(lk, t: 1.5, width: 6, height: 6)
        let want = E.leakColor(lk, 3.5 / 6, 0.5 / 6, 1.5)
        for k in 0..<3 { XCTAssertEqual(Double(lm[3 * 4 + k]), want[k], accuracy: 1e-6) }
        let h = E.Halation(amount: 0.8, threshold: 0.6)
        let (rows, bias, mx) = E.halationMatrix(h)
        let c = SIMD3(0.9, 0.85, 0.7), l = (SIMD3(0.2126, 0.7152, 0.0722) * c).sum()
        let tint = [1, 0.35, 0.2]
        for k in 0..<3 {
            let lin = rows[k][0] * c.x + rows[k][1] * c.y + rows[k][2] * c.z + bias[k]
            XCTAssertEqual(min(max(lin, 0), mx[k]), tint[k] * min(max((l - 0.6) / 0.4, 0), 1) * 0.8, accuracy: 1e-9)
        }
    }
}
