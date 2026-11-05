import XCTest
@testable import MuseCore

/// The Edit suite's editor state (EditSuiteState): every action is undoable, keeps the project valid, and behaves as the
/// designs E1–E4 describe.
final class EditSuiteStateTests: XCTestCase {
    typealias E = EditV2

    private func fixture(_ name: String) throws -> E.Project {
        let c = try XCTUnwrap(editorFixture("projects").array.first { $0["name"].string == name }, name)
        return try c["project"].decode(E.Project.self)
    }

    private func assertValid(_ s: EditSuiteState, file: StaticString = #filePath, line: UInt = #line) {
        let p = E.problem(s.project)
        XCTAssertNil(p, p?.description ?? "", file: file, line: line)
    }

    // MARK: Cutting

    func testSplitDeleteRippleUndoRedo() throws {
        var s = EditSuiteState(try fixture("music ducking"))
        let d0 = s.duration
        s.playhead = 4
        XCTAssertTrue(s.split())
        XCTAssertEqual(s.project.mainClips.count, 2)
        XCTAssertEqual(s.duration, d0, accuracy: 1e-6)
        assertValid(s)
        // Delete the second half: the music and voice after 4 s move left with it (ripple).
        let voiceStart = try XCTUnwrap(s.project.track("voice")?.items.first?.startSec)
        XCTAssertTrue(s.deleteSelected())
        XCTAssertEqual(s.duration, 4, accuracy: 1e-6)
        XCTAssertEqual(s.project.track("mus")?.items.first?.startSec, 0, "music starting before the cut stays")
        if voiceStart >= 4 { XCTAssertLessThan(try XCTUnwrap(s.project.track("voice")?.items.first?.startSec), voiceStart) }
        assertValid(s)
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.project.mainClips.count, 2)
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.project.mainClips.count, 1)
        XCTAssertFalse(s.canUndo)
        XCTAssertTrue(s.redo())
        XCTAssertTrue(s.redo())
        XCTAssertEqual(s.duration, 4, accuracy: 1e-6)
    }

    func testDeleteWithoutRippleLeavesOtherTracks() throws {
        var s = EditSuiteState(try fixture("music ducking"))
        s.ripple = false
        s.playhead = 3
        XCTAssertTrue(s.split())
        let before = s.project.track("voice")
        XCTAssertTrue(s.deleteSelected())
        XCTAssertEqual(s.project.track("voice"), before)
    }

    func testSplitOverlayTextAndAudio() throws {
        var s = EditSuiteState(try fixture("pip text image look"))
        let text = try XCTUnwrap(s.project.track("txt")?.items.first)
        s.selection = text.id
        s.playhead = text.startSec + text.lengthSec / 2
        XCTAssertTrue(s.split())
        XCTAssertEqual(s.project.track("txt")?.items.count, 3)
        assertValid(s)
        let pip = try XCTUnwrap(s.project.track("pipt")?.items.first)
        s.selection = pip.id
        s.playhead = pip.startSec + 1
        XCTAssertTrue(s.split())
        let parts = try XCTUnwrap(s.project.track("pipt")?.items.compactMap(\.videoClip))
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].outSec, parts[1].inSec, accuracy: 1e-9)
        assertValid(s)
    }

    func testLockedRowsCantChange() throws {
        var s = EditSuiteState(try fixture("pip text image look"))
        s.toggleLocked("txt")
        let id = try XCTUnwrap(s.project.track("txt")?.items.first?.id)
        s.selection = id
        XCTAssertFalse(s.deleteSelected())
        XCTAssertNil(s.trimming(id, .end, to: 5))
        s.selection = nil
        s.select(at: 1, trackId: "txt")
        XCTAssertNotEqual(s.selection, id)
    }

    func testHiddenAndMutedAreUndoable() throws {
        var s = EditSuiteState(try fixture("music ducking"))
        XCTAssertTrue(s.toggleHidden("main"))
        XCTAssertEqual(s.project.track("main")?.hidden, true)
        XCTAssertTrue(s.toggleMuted("mus"))
        XCTAssertEqual(s.project.track("mus")?.muted, true)
        s.undo(); s.undo()
        XCTAssertNil(s.project.track("main")?.hidden)
        XCTAssertNil(s.project.track("mus")?.muted)
    }

    // MARK: Trim, move, beats

    func testTrimAndMoveWithBeatSnapping() throws {
        var s = EditSuiteState(try fixture("music ducking"))
        let m = try XCTUnwrap(s.project.track("mus")?.items.first?.id)
        XCTAssertTrue(s.setBeats(m, beats: [5.5, 6, 6.5, 7, 7.5, 8, 8.5, 9], strong: [5.5, 7.5]), "source seconds; the clip starts at 5 s of the song")
        XCTAssertEqual(s.bpm ?? 0, 120, accuracy: 0.01)
        s.beatMarks = .strong
        XCTAssertEqual(s.beats.map(\.t), [0.5, 2.5])
        s.beatMarks = .every
        XCTAssertEqual(s.beats.count, 8)
        s.snapToBeats = true
        XCTAssertEqual(s.snapped(1.93), 2)
        XCTAssertEqual(s.snapped(2.3), 2.3, "too far from a beat")
        // Trim the main clip's end to ~3 s: snapped to the beat at 3.
        let c = try XCTUnwrap(s.project.mainClips.first)
        s.beginGesture()
        let trimmed = s.trimming(c.id, .end, to: 3.05)
        s.updateGesture(trimmed)
        s.endGesture()
        XCTAssertEqual(s.duration, 3, accuracy: 1e-6)
        assertValid(s)
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.duration, 10, accuracy: 1e-6)
        // Move the voice-over to 1.4 → 1.5 (beat).
        let vo = try XCTUnwrap(s.project.track("voice")?.items.first?.id)
        let q = try XCTUnwrap(s.moving(vo, to: 1.42))
        XCTAssertEqual(q.track("voice")?.items.first?.startSec, 1.5)
    }

    func testTrimStartOfMainClip() throws {
        var s = EditSuiteState(try fixture("single clip"))
        let c = try XCTUnwrap(s.project.mainClips.first)
        let q = try XCTUnwrap(s.trimming(c.id, .start, to: 1))
        XCTAssertEqual(q.mainClips[0].inSec, c.inSec + 1, accuracy: 1e-6)
        s.apply { _ in q }
        assertValid(s)
    }

    // MARK: Speed

    func testSpeedCurvesAndConstant() throws {
        var s = EditSuiteState(try fixture("single clip"))
        let d0 = s.duration
        XCTAssertTrue(s.setSpeedPreset(.hero))
        let c = try XCTUnwrap(s.selectedVideo)
        XCTAssertEqual(c.speedCurve?.preset, .hero)
        XCTAssertLessThan(s.duration, d0)
        XCTAssertNotNil(s.speedSummary)
        assertValid(s)
        // Drag a point: custom.
        let moved = EditSuiteState.movingCurvePoint(try XCTUnwrap(c.speedCurve), 2, x: 0.45, speed: 20)
        XCTAssertEqual(moved.preset, .custom)
        XCTAssertEqual(moved.points[2][1], 10, "clamped")
        XCTAssertTrue(s.setSpeedCurve(moved))
        assertValid(s)
        let added = EditSuiteState.addingCurvePoint(moved, x: 0.9)
        XCTAssertEqual(added.points.count, moved.points.count + 1)
        XCTAssertTrue(s.setSpeed(0.5))
        XCTAssertNil(s.selectedVideo?.speedCurve)
        XCTAssertEqual(s.duration, d0 * 2, accuracy: 1e-6)
        // A split keeps each half's part of a curve.
        s.setSpeedPreset(.montage)
        s.playhead = s.duration / 2
        XCTAssertTrue(s.split())
        XCTAssertEqual(s.project.mainClips.compactMap(\.speedCurve).count, 2)
        XCTAssertTrue(s.project.mainClips.allSatisfy { $0.speedCurve?.preset == .custom })
        assertValid(s)
    }

    // MARK: Transitions

    func testTransitionsFitAndApplyToAll() throws {
        var s = EditSuiteState(try fixture("cut and speeds"))
        s.selection = s.project.mainClips[1].id
        XCTAssertTrue(s.setTransition(.whip, duration: 5))
        let tr = try XCTUnwrap(s.project.mainClips[1].transitionIn)
        XCTAssertEqual(tr.kind, .whip)
        XCTAssertLessThanOrEqual(tr.durationSec, 2)
        assertValid(s)
        XCTAssertTrue(s.applyTransitionToAll(.glitch, duration: 0.3))
        XCTAssertTrue(s.project.mainClips.dropFirst().allSatisfy { $0.transitionIn?.kind == .glitch })
        assertValid(s)
        XCTAssertTrue(s.applyTransitionToAll(nil, duration: 0.3))
        XCTAssertTrue(s.project.mainClips.allSatisfy { $0.transitionIn == nil })
        XCTAssertEqual(E.transitionLabel(nil), "Cut")
        XCTAssertEqual(E.transitionLabel(.fade), "X-fade")
    }

    // MARK: Captions and hooks

    func testCaptionsTranscriptEditByTextAndCuts() throws {
        var s = EditSuiteState(try fixture("single clip"))
        let words = FakeMuseAPI.mockWords(duration: 10)
        XCTAssertTrue(s.setCaptions(words: words, assetId: "src"))
        XCTAssertEqual(s.project.captionTrack?.style.preset, .pop)
        assertValid(s)
        let tr = s.transcript()
        XCTAssertEqual(tr.count, words.count)
        XCTAssertEqual(tr.filter(\.isFiller).map(\.text), ["um", "like", "uh"].filter { w in tr.contains { $0.text == w && $0.isFiller } })
        XCTAssertFalse(s.fillerCuts.isEmpty)
        XCTAssertFalse(s.silenceCuts().isEmpty, "the sample has long pauses")
        // Cut silences first, then fillers.
        let d0 = s.duration
        XCTAssertTrue(s.applyCuts(s.silenceCuts(), assetId: "src"))
        let d1 = s.duration
        XCTAssertLessThan(d1, d0)
        XCTAssertTrue(s.applyCuts(s.fillerCuts, assetId: "src"))
        XCTAssertLessThan(s.duration, d1)
        XCTAssertTrue(s.transcript().filter(\.isFiller).allSatisfy { !$0.kept })
        assertValid(s)
        // Edit by text: delete two words.
        let keptBefore = s.transcript().filter(\.kept).count
        XCTAssertTrue(s.deleteWords([1, 2]))
        XCTAssertLessThan(s.transcript().filter(\.kept).count, keptBefore)
        // Fix a spelling.
        XCTAssertTrue(s.editWord(0, text: "Hi"))
        XCTAssertEqual(s.project.captionTrack?.words[0].text, "Hi")
        XCTAssertFalse(s.editWord(0, text: "  "))
        // Styles keep the position.
        XCTAssertTrue(s.changeCaptionStyle { $0.y = EditSuite.CaptionPosition.top.y })
        XCTAssertTrue(s.setCaptionPreset(.neon))
        XCTAssertEqual(s.captionStyle?.preset, .neon)
        XCTAssertEqual(s.captionStyle?.y, 0.2)
        XCTAssertEqual(s.captionStyle?.highlightColor, "#FF2D87")
        assertValid(s)
        XCTAssertFalse(E.toSrt(s.project).isEmpty)
    }

    func testHooksAndText() throws {
        var s = EditSuiteState(try fixture("single clip"))
        let hook = try XCTUnwrap(E.hooks.first)
        XCTAssertTrue(s.addHook(hook, text: "3 things I wish I knew"))
        let row = try XCTUnwrap(s.project.tracks.first { $0.name == "Hook" })
        XCTAssertEqual(row.items.first?.textItem?.template, hook.id)
        XCTAssertEqual(s.tab, .text)
        // A second hook at 0 replaces the first.
        XCTAssertTrue(s.addHook(E.hooks[2]))
        XCTAssertEqual(s.project.tracks.first { $0.name == "Hook" }?.items.count, 1)
        s.playhead = 5
        XCTAssertTrue(s.addText("hello"))
        assertValid(s)
        XCTAssertEqual(s.rows.first?.label, "HOOK", "hook row on top")
        XCTAssertEqual(s.rows.last?.kind, .main)
    }

    // MARK: Media, audio

    func testAddMediaAndAudioMix() throws {
        var s = EditSuiteState(try fixture("single clip"))
        XCTAssertTrue(s.addVideo(E.Asset(id: "t2", kind: .video, take: "tk2", durationSec: 4)))
        XCTAssertEqual(s.project.mainClips.count, 2)
        s.playhead = 1
        XCTAssertTrue(s.addVideo(E.Asset(id: "t3", kind: .video, take: "tk3", durationSec: 3), overlay: true))
        XCTAssertNotNil(s.project.tracks.first { $0.kind == .video })
        XCTAssertTrue(s.addAudio(E.Asset(id: "song", kind: .audio, upload: "up1", durationSec: 60), kind: .music))
        XCTAssertTrue(s.setAutoDuck(true))
        let duck = try XCTUnwrap(s.musicTrack?.duck)
        XCTAssertEqual(EditSuite.db(gain: duck.level ?? 1), -12)
        XCTAssertEqual(duck.attackSec, 0.2)
        XCTAssertEqual(duck.releaseSec, 0.6)
        XCTAssertTrue(s.changeDuck { $0?.releaseSec = 1.2 })
        s.selection = s.project.mainClips[0].id
        XCTAssertTrue(s.changeSound { $0.voiceEffect = .radio; $0.enhance = true; $0.volume = EditSuite.gain(db: -3) })
        XCTAssertEqual(s.selectedSound?.voiceEffect, .radio)
        assertValid(s)
        XCTAssertTrue(s.addImage(E.Asset(id: "st", kind: .image, library: "sticker-heart")))
        assertValid(s)
    }

    func testVisualAdjustMaskLookAndKeyframes() throws {
        var s = EditSuiteState(try fixture("single clip"))
        XCTAssertTrue(s.changeVisual { $0.adjust = E.Adjust(exposure: 0.1, highlights: -0.12, shadows: 0.05) })
        XCTAssertTrue(s.changeVisual { $0.mask = E.Mask(shape: .circle, feather: 0.3) })
        XCTAssertTrue(s.changeVisual { var g = $0.look ?? E.Look(); g.grain = E.Grain(amount: 0.2); $0.look = g })
        s.playhead = 2
        XCTAssertTrue(s.addKeyframe(.scale, value: 1.12))
        s.playhead = 5
        XCTAssertTrue(s.addKeyframe(.scale, value: 1.3))
        XCTAssertEqual(s.selectedVisual?.keyframes?.scale?.count, 2)
        XCTAssertTrue(s.setKeyframeEase(.linear))
        assertValid(s)
        XCTAssertEqual(s.history.undoCount, 6)
    }

    // MARK: Shape and export

    func testRatioAndExportSettings() throws {
        var s = EditSuiteState(try fixture("single clip"))
        XCTAssertEqual(s.export.ratio, .portrait)
        XCTAssertEqual(s.export.resolution, .p1080)
        XCTAssertFalse(s.export.labelAI, "disclosure off by default")
        XCTAssertFalse(s.export.c2pa, "disclosure off by default")
        XCTAssertTrue(s.setRatio(.landscape))
        XCTAssertEqual(s.project.canvas.width, 1920)
        XCTAssertEqual(s.project.canvas.height, 1080)
        assertValid(s)
        XCTAssertEqual(EditSuite.Ratio.vertical.canvas(shortSide: 1080).height, 1350)
        XCTAssertEqual(EditSuite.Ratio.square.canvas(shortSide: 2160).width, 2160)
        var ex = EditSuite.ExportSettings()
        XCTAssertEqual(ex.summary(durationSec: 18), "0:18 · 1080 × 1920 · 30 fps")
        XCTAssertEqual(ex.sizeLabel(durationSec: 18), "≈ 36 MB")
        ex.codec = .hevc
        XCTAssertLessThan(ex.estimatedBytes(durationSec: 18), 30_000_000)
        XCTAssertEqual(EditorEstimate.label(free: true, usd: 0.3), "Free")
        XCTAssertEqual(EditorEstimate.label(free: false, usd: 0.04), "≈ $0.04")
    }

    func testFramingFollowsFaces() throws {
        var p = try fixture("single clip")
        p.assets[0].width = 1920
        p.assets[0].height = 1080
        var s = EditSuiteState(p)
        // A landscape source on a 9:16 canvas overflows sideways: a face at 30 % moves right of centre.
        XCTAssertTrue(s.setRatio(.portrait, framing: ["c1": 0.3]))
        let x = try XCTUnwrap(s.project.mainClips[0].transform?.x)
        XCTAssertGreaterThan(x, 0.5)
        assertValid(s)
    }

    func testClocks() {
        XCTAssertEqual(EditSuite.clockTenths(4.2), "0:04.2")
        XCTAssertEqual(EditSuite.clock(18), "0:18")
        XCTAssertEqual(EditSuite.clock(75), "1:15")
    }

    // MARK: Fake API helpers

    func testFakeEditorJobs() async throws {
        let api = FakeMuseAPI(speed: 50)
        let takes = try await api.listTakes()
        let take = try XCTUnwrap(takes.first { $0.isVideo })
        let est = try await api.editorEstimate(EditorJobRequest(kind: .captions, source: EditorSource(takeId: take.id)))
        XCTAssertTrue(est.free)
        let job = try await api.startEditorJob(EditorJobRequest(kind: .beats, source: EditorSource(takeId: take.id)))
        var j = job
        for _ in 0..<100 where j.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
            j = try await api.editorJob(id: job.id)
        }
        XCTAssertEqual(j.state, "done")
        XCTAssertEqual(j.result?.bpm, 120)
        XCTAssertFalse(j.result?.beats?.isEmpty ?? true)
    }
}
