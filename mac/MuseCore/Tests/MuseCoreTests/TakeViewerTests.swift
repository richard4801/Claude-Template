import XCTest
@testable import MuseCore

/// The take viewer (plans/swap-viewer-design.md §B): skins per shape and safe zones (now Edit's; defaults and the server's
/// table), the frame maths (no letterbox), the keys (space, ← → 3 s and ⇧ 10 s, J/K/L), the seek readout, the phone's double-tap,
/// the actions per context and the order their labels give way, and New Swap's trimmer.
final class TakeViewerTests: XCTestCase {
    func testPortraitGetsThePhoneLayoutsAndLandscapeTheDesktopOnes() {
        XCTAssertEqual(PreviewSkin.options(aspect: 9.0 / 16.0), [.clean, .tiktok, .reels, .shorts, .facebook])
        XCTAssertEqual(PreviewSkin.options(aspect: 1), [.clean, .tiktok, .reels, .shorts, .facebook])
        XCTAssertEqual(PreviewSkin.options(aspect: 16.0 / 9.0), [.clean, .youtube, .facebook])
    }

    func testSafeZonesComeFromTheServerTableOverTheDefaults() throws {
        let json = #"{"zones":{"tiktok":{"top":0.12,"bottom":0.3,"left":0.02,"right":0.18}},"note":"From the server"}"#
        let server = try JSONDecoder().decode(PreviewLayouts.self, from: Data(json.utf8)).merged()
        XCTAssertEqual(server.zone(.tiktok)?.top, 0.12)
        XCTAssertEqual(server.zone(.reels), PreviewLayouts.defaults.zone(.reels)) // left out: keeps its default
        XCTAssertNil(server.zone(.clean))
        XCTAssertNil(server.zone(.youtube))
        XCTAssertEqual(server.note, "From the server")
        let r = try XCTUnwrap(server.zone(.tiktok)).safeRect
        XCTAssertEqual(r.x, 0.02, accuracy: 1e-9)
        XCTAssertEqual(r.w, 0.80, accuracy: 1e-9)
        XCTAssertEqual(r.h, 0.58, accuracy: 1e-9)
        XCTAssertEqual(SafeZone(top: 2, bottom: -1, right: .nan).safeRect.h, 0.5, accuracy: 1e-9) // nonsense is clamped
        // Landscape players: defaults until the server sends its own (an older server sends none).
        XCTAssertEqual(server.landscapeZone(.youtube), PreviewLayouts.defaults.landscapeZone(.youtube))
        XCTAssertNil(server.landscapeZone(.tiktok))
        let wide = try JSONDecoder().decode(PreviewLayouts.self, from: Data(#"{"zones":{},"landscape":{"youtube":{"top":0.2,"bottom":0.2,"left":0,"right":0}}}"#.utf8)).merged()
        XCTAssertEqual(wide.landscapeZone(.youtube)?.top, 0.2)
        XCTAssertEqual(wide.landscapeZone(.facebook), PreviewLayouts.defaults.landscapeZone(.facebook))
    }

    func testThePortraitTakeSitsInAPortraitFrameNeverALetterbox() {
        XCTAssertEqual(ViewerFrame.aspect(width: 1080, height: 1920, isVideo: true), 0.5625, accuracy: 1e-9)
        XCTAssertEqual(ViewerFrame.aspect(width: nil, height: nil, isVideo: false), 0.8, accuracy: 1e-9)
        let f = ViewerFrame.fit(aspect: 9.0 / 16.0, width: 900, height: 640)
        XCTAssertEqual(f.h, 640)
        XCTAssertEqual(f.w, 360) // the frame is the take's own width, not the pane's
        let l = ViewerFrame.fit(aspect: 16.0 / 9.0, width: 800, height: 900)
        XCTAssertEqual(l.w, 800)
        XCTAssertEqual(l.h, 450)
        XCTAssertEqual(ViewerFrame.fit(aspect: .nan, width: 10, height: 10).w, 0)
    }

    func testKeysSpaceArrowsAndShift() {
        var t = ViewerTransport()
        XCTAssertEqual(t.command(for: .space, shift: false), .togglePlay)
        XCTAssertEqual(t.command(for: .right, shift: false), .jump(3))
        XCTAssertEqual(t.command(for: .left, shift: false), .jump(-3))
        XCTAssertEqual(t.command(for: .right, shift: true), .jump(10))
        XCTAssertEqual(t.command(for: .left, shift: true), .jump(-10))
        XCTAssertEqual(t.command(for: .up, shift: false), .previousTake)
        XCTAssertEqual(t.command(for: .down, shift: false), .nextTake)
        XCTAssertEqual(t.command(for: .character(","), shift: false), .frame(-1))
        XCTAssertEqual(t.command(for: .character("M"), shift: true), .mute)
        XCTAssertEqual(t.command(for: .escape, shift: false), .close)
        XCTAssertNil(t.command(for: .character("x"), shift: false))
    }

    func testJKLShuttleSpeedsUpTurnsAroundAndStops() {
        var t = ViewerTransport()
        XCTAssertEqual(t.command(for: .character("l"), shift: false), .shuttle(1))
        XCTAssertEqual(t.command(for: .character("l"), shift: false), .shuttle(2))
        XCTAssertEqual(t.command(for: .character("l"), shift: false), .shuttle(4))
        XCTAssertEqual(t.command(for: .character("l"), shift: false), .shuttle(4))
        XCTAssertEqual(t.command(for: .character("j"), shift: false), .shuttle(2)) // slows first
        XCTAssertEqual(t.command(for: .character("j"), shift: false), .shuttle(1))
        XCTAssertEqual(t.command(for: .character("j"), shift: false), .shuttle(0))
        XCTAssertEqual(t.command(for: .character("j"), shift: false), .shuttle(-1))
        XCTAssertEqual(t.command(for: .character("k"), shift: false), .shuttle(0))
        t.kHeld = true
        XCTAssertEqual(t.command(for: .character("l"), shift: false), .frame(1))
        XCTAssertEqual(t.command(for: .character("j"), shift: false), .frame(-1))
        XCTAssertEqual(ViewerTransport.shuttleLabel(-2), "2× back")
    }

    func testSeekStaysInsideTheTakeAndTheReadoutNamesTheJump() {
        XCTAssertEqual(ViewerTransport.seek(8, by: 3, duration: 10), 10)
        XCTAssertEqual(ViewerTransport.seek(1, by: -3, duration: 10), 0)
        XCTAssertEqual(ViewerTransport.seek(.nan, by: 3, duration: 10), 3)
        XCTAssertEqual(ViewerTransport.readout(delta: 3, time: 7, duration: 10), "+3 s  0:07 / 0:10")
        XCTAssertEqual(ViewerTransport.readout(delta: -10, time: 2, duration: 64), "−10 s  0:02 / 1:04")
        XCTAssertEqual(ViewerTransport.readout(delta: nil, time: 7.4, duration: 10), "0:07 / 0:10")
    }

    func testDoubleTapSidesAddUpAndTheMiddleDoesNothing() {
        XCTAssertEqual(DoubleTapSkip.side(x: 10, width: 390), -1)
        XCTAssertEqual(DoubleTapSkip.side(x: 195, width: 390), 0)
        XCTAssertEqual(DoubleTapSkip.side(x: 380, width: 390), 1)
        var d = DoubleTapSkip()
        XCTAssertEqual(d.tap(side: 1, at: 0), 3)
        XCTAssertEqual(d.tap(side: 1, at: 0.3), 3)
        XCTAssertEqual(d.total, 6)
        _ = d.tap(side: -1, at: 0.5) // the other side starts a new run
        XCTAssertEqual(d.total, -3)
        _ = d.tap(side: -1, at: 2) // too late: a new run
        XCTAssertEqual(d.total, -3)
        XCTAssertEqual(d.tap(side: 0, at: 2.1), 0)
    }

    func testActionsPerContextAndHiddenWhenTheTakeCantDoThem() {
        XCTAssertEqual(TakeViewerActions.list(.suite, isVideo: true, canRedo: true, canExtend: true, canUpscale: true),
                       [.keep, .redo, .extend, .upscale, .split, .share])
        XCTAssertEqual(TakeViewerActions.list(.suite, isVideo: false, canRedo: false, canExtend: true, canUpscale: false), [.keep, .share])
        XCTAssertEqual(TakeViewerActions.list(.compare, isVideo: true, canRedo: true, canExtend: true, canUpscale: true), [.keep])
        XCTAssertEqual(TakeViewerActions.list(.source, isVideo: true, canRedo: true, canExtend: true, canUpscale: true), [])
        XCTAssertEqual(TakeViewerActions.hiddenReasons(isVideo: true, canRedo: true, canExtend: true, canUpscale: false, isMaxResolution: true),
                       ["Upscale: already 4K"])
        XCTAssertEqual(TakeViewerAction.split.help, "Open it in Edit at this moment")
    }

    func testLabelsGiveWayInOrderAndKeepAndShareAlwaysKeepTheirs() {
        let all = TakeViewerActions.list(.suite, isVideo: true, canRedo: true, canExtend: true, canUpscale: true)
        let steps = TakeViewerActions.steps(all)
        XCTAssertEqual(steps, [[], [.split], [.split, .upscale], [.split, .upscale, .extend], [.split, .upscale, .extend, .redo]])
        for s in steps { XCTAssertFalse(s.contains(.keep)); XCTAssertFalse(s.contains(.share)) }
        XCTAssertEqual(TakeViewerActions.steps([.keep, .share]), [[]])
    }

    func testTrimmerKeepsTheWindowInsideTheClipAndTheModelsLimits() {
        var w = TrimWindow.initial(duration: 24, minLen: 2, maxLen: 10, range: nil)
        XCTAssertEqual(w.from, 0)
        XCTAssertEqual(w.to, 10)
        XCTAssertEqual(w.line(model: "Wan 2.7 Edit"), "Uses 0:00–0:10 of 0:24, 10 s. Wan 2.7 Edit takes up to 10 s.")
        w.slide(by: 2)
        XCTAssertEqual(w.from, 2)
        XCTAssertEqual(w.to, 12)
        w.slide(by: 100)
        XCTAssertEqual(w.from, 14)
        XCTAssertEqual(w.to, 24)
        w.moveStart(to: 5) // longer than the model takes: the end follows
        XCTAssertEqual(w.from, 5)
        XCTAssertEqual(w.to, 15)
        w.moveEnd(to: 5.5) // shorter than the model needs: held at the minimum
        XCTAssertEqual(w.to, 7)
        XCTAssertEqual(w.length, 2, accuracy: 1e-9)
        let short = TrimWindow.initial(duration: 6, minLen: 2, maxLen: 10, range: nil)
        XCTAssertTrue(short.wholeClipFits)
        XCTAssertEqual(short.line(model: "Wan 2.7 Edit"), "Uses 0:00–0:06 of 0:06, 6 s.")
        let picked = TrimWindow.initial(duration: 24, minLen: 2, maxLen: 10, range: (3.04, 9.96))
        XCTAssertEqual(picked.from, 3)
        XCTAssertEqual(picked.to, 10)
    }
}

final class TakeViewerAPITests: XCTestCase {
    func testDemoModeGetsTheDefaultSafeZones() async {
        let l = await FakeMuseAPI().previewLayouts()
        XCTAssertEqual(l, .defaults)
    }
}
