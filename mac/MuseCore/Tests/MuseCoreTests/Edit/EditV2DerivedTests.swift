import XCTest
@testable import MuseCore

/// Helper copies (WS8 2df521a): sourceOf / derivedOps / derivedLabel on a chain, deriveClip both ways, and applySlowmo
/// (functions.json → derived, slowmo). Validation cases are in validation.json.
final class EditV2DerivedTests: XCTestCase {
    typealias E = EditV2

    func testChains() throws {
        let d = try editorFixture("functions")["derived"]
        let p = E.Project(sourceTakeId: "tk_1", canvas: E.Canvas(width: 1080, height: 1920, fps: 30),
                          assets: try d["assets"].decode([E.Asset].self), tracks: [])
        let chains = d["chains"].array
        XCTAssertGreaterThanOrEqual(chains.count, 5)
        for c in chains {
            let id = try XCTUnwrap(c["asset"].string)
            XCTAssertEqual(E.sourceOf(p, id), c["source"].string, id)
            XCTAssertEqual(E.derivedOps(p, id), c["ops"].array.compactMap(\.string), id)
            XCTAssertEqual(E.derivedLabel(p, id), c["label"].string, id)
        }
    }

    func testDeriveClip() throws {
        let d = try editorFixture("functions")["derived"]
        let clip = try d["clip"].decode(E.VideoClip.self)
        for s in d["swaps"].array {
            let op = s["op"].string.flatMap(E.DerivedOp.init(rawValue:))
            let got = E.deriveClip(clip, copy: try XCTUnwrap(s["copy"].string), op: op)
            let diff = jsonDiff(try JV.of(got), s["clip"]); XCTAssert(diff.isEmpty, "\(String(describing: op)): " + diff.prefix(4).joined(separator: "; "))
        }
    }

    func testApplySlowmo() throws {
        let cases = try editorFixture("functions")["slowmo"].array
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            let name = c["name"].string ?? "?"
            let p = try c["project"].decode(E.Project.self)
            // As editor-fixtures.ts: clip "c1", copy "src_sm".
            let got = E.applySlowmo(p, clipId: "c1", slowId: "src_sm")
            if c["result"].isNull { XCTAssertNil(got, name); continue }
            let r = try XCTUnwrap(got, name)
            XCTAssertEqual(r.id, c["result"]["id"].string, name)
            let diff = jsonDiff(try JV.of(r.project), c["result"]["project"]); XCTAssert(diff.isEmpty, "\(name): " + diff.prefix(5).joined(separator: "; "))
            XCTAssertNil(E.problem(r.project), name)
        }
    }

    /// Stabilise on the selected clip, then Reverse on top: only the last step switches off.
    func testStabiliseThenReverse() throws {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 10), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        let id = s.project.mainClips[0].id
        s.selection = id
        let orig = s.project.mainClips[0].asset
        var st = E.Asset(id: "src_st", kind: .video, upload: "u_st", durationSec: 10, width: 1080, height: 1920, hasAudio: true)
        st.derivedFrom = E.DerivedFrom(asset: orig, op: .stabilize)
        XCTAssertEqual(s.stabilizeSelected(to: st), [])
        XCTAssertEqual(s.project.mainClips[0].asset, "src_st")
        XCTAssertEqual(s.steadiedFrom, orig)
        XCTAssertEqual(s.selectedSteps, ["stabilize"])
        XCTAssertNil(E.problem(s.project))
        var rev = E.Asset(id: "src_st_rev", kind: .video, upload: "u_rev", durationSec: 10, width: 1080, height: 1920, hasAudio: true)
        rev.reverseOf = "src_st"
        XCTAssertNotNil(s.reverseSelected(to: rev))
        XCTAssertEqual(s.selectedSteps, ["stabilize", "reverse"])
        XCTAssertEqual(s.blockingStep(for: "stabilize"), "reverse")
        XCTAssertNil(s.blockingStep(for: "reverse"))
        XCTAssertEqual(E.derivedLabel(s.project, s.project.mainClips[0].asset), "Steadied, reversed")
        XCTAssertNil(E.problem(s.project))
        // Reverse off, then Stabilise off: back to the original, the copies kept for next time.
        XCTAssertNotNil(s.reverseSelected(to: try XCTUnwrap(s.project.asset("src_st"))))
        XCTAssertNotNil(s.stabilizeSelected(to: try XCTUnwrap(s.project.asset(orig))))
        XCTAssertEqual(s.project.mainClips[0].asset, orig)
        XCTAssertEqual(s.selectedSteps, [])
        XCTAssertNotNil(s.steadiedCopy(of: orig))
    }
}
