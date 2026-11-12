import XCTest
@testable import MuseCore

/// Edit's platform preview (plans/edit-platform-preview.md): views per canvas shape, the red box in every view, captions
/// and text outside it, "Move into the safe area", and the choice remembered per project.
final class EditPlatformPreviewTests: XCTestCase {
    typealias E = EditV2

    private func fixture(_ name: String) throws -> E.Project {
        let c = try XCTUnwrap(editorFixture("projects").array.first { $0["name"].string == name }, name)
        return try c["project"].decode(E.Project.self)
    }

    private func portrait(_ p: E.Project) -> E.Project {
        var q = p
        q.canvas = E.Canvas(width: 1080, height: 1920, fps: p.canvas.fps)
        return q
    }

    func testViewsFollowTheCanvasShape() {
        XCTAssertEqual(EditPreview.options(width: 1080, height: 1920), [.clean, .tiktok, .reels, .shorts, .facebook])
        XCTAssertEqual(EditPreview.options(width: 1080, height: 1350), [.clean, .tiktok, .reels, .shorts, .facebook])
        XCTAssertEqual(EditPreview.options(width: 1920, height: 1080), [.clean, .youtube, .facebook])
        // A TikTok project turned 16:9 shows Clean; the switch keeps its state.
        let p = EditPreview(view: .tiktok, safeArea: false).resolved(width: 1920, height: 1080)
        XCTAssertEqual(p, EditPreview(view: .clean, safeArea: false))
    }

    func testTheRedBoxWorksInEveryView() throws {
        let tt = try XCTUnwrap(EditSafeBox.zone(EditPreview(view: .tiktok), width: 1080, height: 1920))
        XCTAssertEqual(tt, PreviewLayouts.defaults.zone(.tiktok))
        // Clean: the box safe on every app (the largest inset of each side).
        let all = try XCTUnwrap(EditSafeBox.zone(EditPreview(view: .clean), width: 1080, height: 1920))
        XCTAssertEqual(all.top, 0.11, accuracy: 1e-9)
        XCTAssertEqual(all.bottom, 0.30, accuracy: 1e-9)
        XCTAssertEqual(all.right, 0.17, accuracy: 1e-9)
        // Landscape: YouTube's own box; Clean is title-safe.
        XCTAssertEqual(EditSafeBox.zone(EditPreview(view: .youtube), width: 1920, height: 1080), PreviewLayouts.defaults.landscapeZone(.youtube))
        XCTAssertEqual(EditSafeBox.zone(EditPreview(view: .clean), width: 1920, height: 1080), EditSafeBox.titleSafe)
        // Off: no box, whatever the view.
        XCTAssertNil(EditSafeBox.zone(EditPreview(view: .tiktok, safeArea: false), width: 1080, height: 1920))
        XCTAssertEqual(EditSafeBox.covers(EditPreview(view: .tiktok), width: 1080, height: 1920), "TikTok's caption and buttons")
    }

    func testCaptionsLowOnTheFrameAreFlaggedAndMovedIntoTheBox() throws {
        var s = EditSuiteState(portrait(try fixture("single clip")))
        XCTAssertTrue(s.setCaptions(words: FakeMuseAPI.mockWords(duration: 10), assetId: "src"))
        XCTAssertTrue(s.changeCaptionStyle { $0.y = 0.85 })
        let zone = try XCTUnwrap(PreviewLayouts.defaults.zone(.tiktok))
        let found = EditSafeCheck.issues(s.project, zone: zone)
        let caps = try XCTUnwrap(found.first { $0.kind == .captions })
        XCTAssertTrue(caps.edges.contains("bottom"))
        XCTAssertLessThan(caps.startSec, caps.endSec)
        let line = try XCTUnwrap(EditSafeCheck.line(found, covers: "TikTok's caption and buttons"))
        XCTAssertTrue(line.hasPrefix("Captions sit under TikTok's caption and buttons ("), line)

        let fixed = try XCTUnwrap(EditSafeCheck.fixed(s.project, zone: zone))
        XCTAssertTrue(EditSafeCheck.issues(fixed, zone: zone).isEmpty)
        XCTAssertLessThan(fixed.captionTrack?.style.y ?? 1, 0.71)
        XCTAssertNil(E.problem(fixed), "the fix keeps the project valid")
        // Already inside: nothing to fix.
        XCTAssertNil(EditSafeCheck.fixed(fixed, zone: zone))
    }

    func testTextUnderTheRailIsFlaggedAndNudgedIn() throws {
        var s = EditSuiteState(portrait(try fixture("single clip")))
        XCTAssertTrue(s.addText("Wait for it"))
        let id = try XCTUnwrap(s.selection)
        XCTAssertTrue(s.apply { p in
            var q = p
            for ti in q.tracks.indices { for ii in q.tracks[ti].items.indices {
                if case .text(var it) = q.tracks[ti].items[ii], it.id == id { it.transform = E.Transform(x: 0.9, y: 0.5); q.tracks[ti].items[ii] = .text(it) }
            } }
            return q
        })
        let zone = try XCTUnwrap(PreviewLayouts.defaults.zone(.tiktok))
        let issue = try XCTUnwrap(EditSafeCheck.issues(s.project, zone: zone).first { $0.itemId == id })
        XCTAssertEqual(issue.edges, ["right"])
        let fixed = try XCTUnwrap(EditSafeCheck.fixed(s.project, zone: zone))
        XCTAssertTrue(EditSafeCheck.issues(fixed, zone: zone).isEmpty)
        // A long line wider than the box: the fix narrows its wrap width too.
        var long = s
        XCTAssertTrue(long.apply { p in
            var q = p
            for ti in q.tracks.indices { for ii in q.tracks[ti].items.indices {
                if case .text(var it) = q.tracks[ti].items[ii], it.id == id {
                    it.text = "Things nobody tells you about the first week"
                    it.style.maxWidthPct = 0.85
                    q.tracks[ti].items[ii] = .text(it)
                }
            } }
            return q
        })
        let longFixed = try XCTUnwrap(EditSafeCheck.fixed(long.project, zone: zone))
        XCTAssertTrue(EditSafeCheck.issues(longFixed, zone: zone).isEmpty)
        // Clean with the box off has no issues to show (the app asks only when the box is on).
        XCTAssertNil(EditSafeBox.zone(EditPreview(view: .clean, safeArea: false), width: 1080, height: 1920))
    }

    func testTheChoiceIsRememberedPerProjectWithTheDevicesLastForANewOne() throws {
        var prefs = EditPreviewPrefs()
        XCTAssertEqual(prefs.choice(for: "take_a"), EditPreview())
        prefs.set(EditPreview(view: .tiktok), for: "take_a")
        prefs.set(EditPreview(view: .reels, safeArea: false), for: "take_b")
        XCTAssertEqual(prefs.choice(for: "take_a").view, .tiktok)
        XCTAssertEqual(prefs.choice(for: "take_b"), EditPreview(view: .reels, safeArea: false))
        XCTAssertEqual(prefs.choice(for: "take_new"), EditPreview(view: .reels, safeArea: false)) // the device's last
        for i in 0..<(EditPreviewPrefs.kept + 5) { prefs.set(EditPreview(view: .shorts), for: "t\(i)") }
        XCTAssertLessThanOrEqual(prefs.byProject.count, EditPreviewPrefs.kept)
        let back = try JSONDecoder().decode(EditPreviewPrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(back, prefs)
    }
}
