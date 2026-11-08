import XCTest
@testable import MuseCore

/// Every edit op Claude can apply (apply_edit_ops; fixture ops.json from the server's reference, 2026-11-08 audit): the Mac
/// decodes the result without losing a field, finds it valid and can plan it for playback.
final class EditV2OpsFixtureTests: XCTestCase {
    typealias E = EditV2

    func testEveryClaudeOpGivesAProjectTheMacPlays() throws {
        let cases = try editorFixture("ops").array
        XCTAssertGreaterThanOrEqual(cases.count, 22, "one case per op")
        for c in cases {
            let name = c["name"].string ?? "?"
            let raw = c["project"]
            let p = try raw.decode(E.Project.self)
            let d = jsonStrictDiff(try JV.of(p), raw)
            XCTAssert(d.isEmpty, "\(name) loses fields: " + d.prefix(5).joined(separator: "; "))
            XCTAssertNoThrow(try E.validate(p), name)
            var media: [String: E.MediaInfo] = [:]
            for a in p.assets where a.kind == .video || a.kind == .audio {
                media[a.id] = E.MediaInfo(durationSec: a.durationSec ?? 10, hasVideo: a.kind == .video, hasAudio: a.hasAudio ?? (a.kind == .audio),
                                          width: a.width ?? p.canvas.width, height: a.height ?? p.canvas.height)
            }
            let plan = E.renderPlan(p, media: media)
            XCTAssertGreaterThan(plan.durationSec, 0, name)
            XCTAssertFalse(plan.video.isEmpty, name)
        }
    }
}
