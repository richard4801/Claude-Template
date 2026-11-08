import XCTest
@testable import MuseCore

/// Mac Edit audit (plans/mac-edit-audit.md): every control of the Edit suite, through the same EditSuiteState call the view
/// makes, must change the project exactly as it says (not just "not crash"), stay valid for the server, and undo.
final class EditSuiteControlsTests: XCTestCase {
    typealias E = EditV2

    /// A 10 s 1080 × 1920 take with sound.
    private func fresh() -> EditSuiteState {
        let p = E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 10), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true))
        return EditSuiteState(p)
    }

    private func valid(_ s: EditSuiteState, file: StaticString = #filePath, line: UInt = #line) {
        let p = E.problem(s.project)
        XCTAssertNil(p, p?.description ?? "", file: file, line: line)
    }

    /// Runs `op`, checks it changed the project, the result is valid, and one undo brings the old project back.
    private func undoable(_ s: inout EditSuiteState, file: StaticString = #filePath, line: UInt = #line, _ op: (inout EditSuiteState) -> Bool) {
        let before = s.project
        XCTAssertTrue(op(&s), "the control changed nothing", file: file, line: line)
        XCTAssertNotEqual(s.project, before, file: file, line: line)
        valid(s, file: file, line: line)
        var u = s
        XCTAssertTrue(u.undo(), file: file, line: line)
        XCTAssertEqual(u.project, before, "undo restores the project", file: file, line: line)
    }

    /// The envelope's gain at timeline t (linear between points).
    private func gain(_ env: [E.GainPoint], at t: Double) -> Double {
        guard let f = env.first else { return 0 }
        if t <= f.t { return f.gain }
        for (a, b) in zip(env, env.dropFirst()) where t >= a.t && t <= b.t {
            return b.t - a.t < 1e-9 ? b.gain : a.gain + (b.gain - a.gain) * (t - a.t) / (b.t - a.t)
        }
        return env.last!.gain
    }

    // MARK: Top bar

    func testAspectRatioChangesTheCanvas() {
        var s = fresh()
        undoable(&s) { $0.setRatio(.square) }
        XCTAssertEqual(s.project.canvas.width, s.project.canvas.height)
        XCTAssertEqual(s.export.ratio, .square)
        undoable(&s) { $0.setRatio(.landscape) }
        XCTAssertGreaterThan(s.project.canvas.width, s.project.canvas.height)
        // Framing moves the clip so the face (left third of the source) is in the middle of a wider-than-canvas picture.
        var f = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 10), E.SourceFacts(width: 1920, height: 1080, fps: 30, hasAudio: true)))
        XCTAssertTrue(f.setRatio(.portrait, framing: ["c1": 0.3]))
        XCTAssertGreaterThan(f.project.mainClips[0].transform?.x ?? 0.5, 0.5)
    }

    // MARK: Media

    func testAddTakeToTheEndAndAsOverlay() {
        var s = fresh()
        let a = E.Asset(id: "t2", kind: .video, take: "tk2", durationSec: 4, width: 1080, height: 1920, hasAudio: true)
        undoable(&s) { $0.addVideo(a) }
        XCTAssertEqual(s.project.mainClips.count, 2)
        XCTAssertEqual(s.duration, 14, accuracy: 1e-6)
        s.playhead = 2
        undoable(&s) { $0.addVideo(a, overlay: true) }
        let ov = s.project.tracks.first { $0.kind == .video }?.items.first?.videoClip
        XCTAssertEqual(ov?.startSec, 2)
        XCTAssertEqual(ov?.asset, "t2")
    }

    func testAddMusicVoiceSoundAndPicture() {
        var s = fresh()
        let song = E.Asset(id: "a1", kind: .audio, upload: "up1", durationSec: 30, hasAudio: true)
        undoable(&s) { $0.addAudio(song, kind: .music) }
        XCTAssertEqual(s.project.tracks.first { $0.kind == .music }?.items.first?.audioClip?.outSec ?? 0, 10, accuracy: 1e-6, "music is cut at the video's end")
        s.playhead = 3
        undoable(&s) { $0.addAudio(song, kind: .voice) }
        XCTAssertEqual(s.project.tracks.first { $0.kind == .voice }?.items.first?.startSec, 3)
        undoable(&s) { $0.addAudio(song, kind: .sfx) }
        XCTAssertNotNil(s.project.tracks.first { $0.kind == .sfx })
        let pic = E.Asset(id: "p1", kind: .image, upload: "up2", width: 512, height: 512)
        undoable(&s) { $0.addImage(pic) }
        XCTAssertEqual(s.project.tracks.first { $0.kind == .image }?.items.first?.startSec, 3)
    }

    // MARK: Text and hooks

    func testAddTextAndEveryTextStyleControl() throws {
        var s = fresh()
        s.playhead = 1
        undoable(&s) { $0.addText() }
        let id = try XCTUnwrap(s.selection)
        func change(_ f: @escaping (inout E.TextItem) -> Void) -> (inout EditSuiteState) -> Bool {
            { st in st.changeSelected { it in if case .text(var x) = it { f(&x); it = .text(x) } } }
        }
        undoable(&s, change { $0.text = "Hello" })
        undoable(&s, change { $0.style.font = .serif })
        undoable(&s, change { $0.style.color = "#FF0000" })
        undoable(&s, change { $0.style.weight = 400 })
        undoable(&s, change { $0.style.sizePct = 0.08 })
        undoable(&s, change { $0.style.align = .left })
        undoable(&s, change { $0.style.stroke = nil })
        undoable(&s, change { $0.style.background = E.TextBackground(color: "#FFFFFF", opacity: 1, paddingPct: 0.3, radiusPct: 0.2) })
        undoable(&s, change { $0.style.uppercase = true })
        undoable(&s, change { $0.durationSec = 2 })
        let tx = try XCTUnwrap(s.project.tracks.flatMap(\.items).first { $0.id == id }?.textItem)
        XCTAssertEqual(tx.text, "Hello")
        XCTAssertEqual(tx.style.font, .serif)
        XCTAssertEqual(tx.durationSec, 2)
        XCTAssertEqual(tx.style.uppercase, true)
    }

    func testTextRunningIntoTheNextIsRefusedNotBroken() throws {
        var s = fresh()
        s.playhead = 0
        XCTAssertTrue(s.addText("one"))
        let first = try XCTUnwrap(s.selection)
        s.playhead = 4
        XCTAssertTrue(s.addText("two"))
        s.selection = first
        // The Duration slider pulled to 6 s would overlap "two" (at 4 s): refused, with the reason, and nothing changes.
        let before = s.project
        XCTAssertFalse(s.changeSelected { it in if case .text(var x) = it { x.durationSec = 6; it = .text(x) } })
        XCTAssertEqual(s.project, before)
        XCTAssertNotNil(s.lastRefusal)
        valid(s)
    }

    func testHookGoesOnTheHookRow() {
        var s = fresh()
        undoable(&s) { $0.addHook(E.hooks[0]) }
        let row = s.project.tracks.first { $0.name == "Hook" }
        XCTAssertEqual(row?.items.first?.startSec, 0)
        XCTAssertEqual(row?.items.first?.textItem?.template, E.hooks[0].id)
        // A second hook at 0 replaces the first.
        XCTAssertTrue(s.addHook(E.hooks[1]))
        XCTAssertEqual(s.project.tracks.first { $0.name == "Hook" }?.items.count, 1)
    }

    // MARK: Timeline tools

    func testSplitDeleteAndRipple() {
        var s = fresh()
        s.playhead = 4
        undoable(&s) { $0.split() }
        XCTAssertEqual(s.project.mainClips.map(\.outSec), [4, 10])
        s.selection = s.project.mainClips[0].id
        undoable(&s) { $0.deleteSelected() }
        XCTAssertEqual(s.duration, 6, accuracy: 1e-6)
        XCTAssertEqual(s.project.mainClips.first?.inSec, 4)
    }

    func testTrimDragChangesInAndOut() throws {
        var s = fresh()
        let id = s.project.mainClips[0].id
        s.beginGesture()
        s.updateGesture(s.trimming(id, .start, to: 1.5))
        s.updateGesture(s.trimming(id, .start, to: 2))
        s.endGesture()
        XCTAssertEqual(s.project.mainClips[0].inSec, 2, accuracy: 1e-6)
        s.beginGesture()
        s.updateGesture(s.trimming(id, .end, to: 6))
        s.endGesture()
        XCTAssertEqual(s.project.mainClips[0].outSec, 8, accuracy: 1e-6)
        valid(s)
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.project.mainClips[0].outSec, 10, accuracy: 1e-6, "one undo step per drag")
    }

    func testMoveItemAndReorderMainClips() throws {
        var s = fresh()
        s.playhead = 1
        XCTAssertTrue(s.addText("move me"))
        let id = try XCTUnwrap(s.selection)
        s.beginGesture()
        s.updateGesture(s.moving(id, to: 5))
        s.endGesture()
        XCTAssertEqual(s.project.tracks.flatMap(\.items).first { $0.id == id }?.startSec, 5)
        s.playhead = 3
        s.selection = s.project.mainClips[0].id
        XCTAssertTrue(s.split())
        let order = s.project.mainClips.map(\.id)
        undoable(&s) { $0.moveMainClip(order[1], to: 0) }
        XCTAssertEqual(s.project.mainClips.map(\.id), [order[1], order[0]])
        XCTAssertEqual(s.project.mainClips[0].inSec, 3)
    }

    func testTrackMuteHideLock() throws {
        var s = fresh()
        let main = try XCTUnwrap(s.project.mainTrack?.id)
        undoable(&s) { $0.toggleMuted(main) }
        XCTAssertEqual(s.project.mainTrack?.muted, true)
        // Muted: the main clip has no sound in the render plan.
        XCTAssertTrue(E.renderPlan(s.project, media: ["src": E.MediaInfo(durationSec: 10, hasVideo: true, hasAudio: true, width: 1080, height: 1920)]).audio.isEmpty)
        undoable(&s) { $0.toggleHidden(main) }
        XCTAssertTrue(E.renderPlan(s.project, media: ["src": E.MediaInfo(durationSec: 10, hasVideo: true, hasAudio: true, width: 1080, height: 1920)]).video.isEmpty)
        s.toggleLocked(main)
        s.playhead = 5
        XCTAssertFalse(s.split(), "a locked row can't be cut")
    }

    func testSnapToBeats() {
        var s = fresh()
        XCTAssertTrue(s.addAudio(E.Asset(id: "a1", kind: .audio, upload: "u", durationSec: 30, hasAudio: true), kind: .music))
        let m = s.project.tracks.first { $0.kind == .music }!.items[0].id
        undoable(&s) { $0.setBeats(m, beats: [1, 2, 3, 4], strong: [2, 4]) }
        s.snapToBeats = true
        s.selection = s.project.mainClips[0].id
        s.playhead = 3.95
        XCTAssertTrue(s.split())
        XCTAssertEqual(s.project.mainClips[0].outSec, 4, accuracy: 1e-6, "the cut lands on the beat")
    }

    // MARK: Speed

    func testSpeedConstantPresetAndCurve() throws {
        var s = fresh()
        undoable(&s) { $0.setSpeed(2) }
        XCTAssertEqual(s.duration, 5, accuracy: 1e-6)
        undoable(&s) { $0.setSpeedPreset(.montage) }
        XCTAssertEqual(s.selectedVideo?.speedCurve?.preset, .montage)
        let c = try XCTUnwrap(s.selectedVideo?.speedCurve)
        undoable(&s) { $0.setSpeedCurve(EditSuiteState.movingCurvePoint(c, 1, x: 0.4, speed: 3)) }
        XCTAssertEqual(s.selectedVideo?.speedCurve?.preset, .custom)
        undoable(&s) { $0.setSpeedPreset(nil) }
        XCTAssertNil(s.selectedVideo?.speedCurve)
    }

    // MARK: Transitions

    func testTransitionsDurationAndApplyToAll() {
        var s = fresh()
        s.playhead = 3; XCTAssertTrue(s.split())
        s.playhead = 7; XCTAssertTrue(s.split())
        s.selection = s.project.mainClips[1].id
        undoable(&s) { $0.setTransition(.fade, duration: 0.5) }
        XCTAssertEqual(s.project.mainClips[1].transitionIn?.kind, .fade)
        undoable(&s) { $0.setTransition(.fade, duration: 1) }
        XCTAssertEqual(s.project.mainClips[1].transitionIn?.durationSec ?? 0, 1, accuracy: 1e-6)
        undoable(&s) { $0.applyTransitionToAll(.whip, duration: 0.4) }
        XCTAssertEqual(s.project.mainClips.dropFirst().map { $0.transitionIn?.kind }, [.whip, .whip])
        undoable(&s) { $0.setTransition(nil, duration: 0.4) }
        XCTAssertNil(s.project.mainClips[1].transitionIn)
    }

    // MARK: Transform, keyframes, crop

    func testTransformSlidersStaticThenKeyframed() {
        var s = fresh()
        undoable(&s) { $0.setVisualValue(.x, 0.3) }
        undoable(&s) { $0.setVisualValue(.y, 0.6) }
        undoable(&s) { $0.setVisualValue(.scale, 1.5) }
        undoable(&s) { $0.setVisualValue(.rotation, 15) }
        undoable(&s) { $0.setVisualValue(.opacity, 0.5) }
        let tf = s.selectedVideo?.transform
        XCTAssertEqual(tf?.x, 0.3); XCTAssertEqual(tf?.y, 0.6); XCTAssertEqual(tf?.scale, 1.5); XCTAssertEqual(tf?.rotation, 15)
        XCTAssertEqual(s.selectedVideo?.opacity, 0.5)
        // Keyframe scale at 2 s, then move the slider at 6 s: a second key (the static value would be ignored).
        s.playhead = 2
        undoable(&s) { $0.addKeyframe(.scale, value: 1.5) }
        s.playhead = 6
        undoable(&s) { $0.setVisualValue(.scale, 2) }
        XCTAssertEqual(s.selectedVideo?.keyframes?.scale?.map(\.t), [2, 6])
        XCTAssertEqual(s.visualValue(.scale) ?? 0, 2, accuracy: 1e-6)
        s.playhead = 4
        XCTAssertEqual(s.visualValue(.scale) ?? 0, 1.75, accuracy: 1e-6, "halfway between the keys (ease in-out at p = 0.5)")
        // And the picture follows: placement at 4 s.
        XCTAssertEqual(E.placement(s.selectedVideo!, local: 4).scale, 1.75, accuracy: 1e-6)
    }

    func testKeyframeAllRemoveEaseAndNavigate() {
        var s = fresh()
        s.playhead = 1
        undoable(&s) { $0.addKeyframesAll() }
        let k = s.selectedVideo?.keyframes
        XCTAssertEqual(k?.x?.count, 1); XCTAssertEqual(k?.y?.count, 1); XCTAssertEqual(k?.scale?.count, 1)
        XCTAssertEqual(k?.rotation?.count, 1); XCTAssertEqual(k?.opacity?.count, 1)
        s.playhead = 5
        XCTAssertTrue(s.setVisualValue(.x, 0.8))
        XCTAssertEqual(s.adjacentKeyframe(-1) ?? -1, 1, accuracy: 1e-6)
        s.playhead = 0
        XCTAssertEqual(s.adjacentKeyframe(1) ?? -1, 1, accuracy: 1e-6)
        undoable(&s) { $0.setKeyframeEase(.linear) }
        XCTAssertEqual(s.selectedVideo?.keyframes?.x?.first?.ease, .linear)
        s.playhead = 5
        XCTAssertTrue(s.hasKeyframe(.x))
        undoable(&s) { $0.removeKeyframe(.x) }
        XCTAssertEqual(s.selectedVideo?.keyframes?.x?.count, 1)
        s.playhead = 1
        undoable(&s) { $0.removeKeyframe(.x) }
        XCTAssertNil(s.selectedVideo?.keyframes?.x, "the last key gone")
        XCTAssertEqual(s.selectedVideo?.transform?.x, 0.5, "keeps the value it had")
    }

    func testCropAndReset() {
        var s = fresh()
        undoable(&s) { $0.setCrop(.left, 0.1) }
        undoable(&s) { $0.setCrop(.top, 0.2) }
        undoable(&s) { $0.setCrop(.right, 0.9) }   // clamped to 0.45
        undoable(&s) { $0.setCrop(.bottom, 0.05) }
        XCTAssertEqual(s.selectedVideo?.crop, E.Crop(left: 0.1, top: 0.2, right: 0.45, bottom: 0.05))
        undoable(&s) { $0.resetTransform() }
        XCTAssertNil(s.selectedVideo?.crop)
    }

    // MARK: Looks, adjust, mask, chroma

    func testLookIntensityAdjustAndGrain() {
        var s = fresh()
        undoable(&s) { $0.changeVisual { $0.look = E.Look(lut: "pack:\(E.lookPackIds[0])", strength: 1) } }
        undoable(&s) { $0.changeVisual { $0.look?.strength = 0.4 } }
        for (i, key) in ["exposure", "contrast", "saturation", "temperature", "highlights", "shadows"].enumerated() {
            undoable(&s) { st in
                st.changeVisual { v in
                    var a = v.adjust ?? E.Adjust()
                    switch key {
                    case "exposure": a.exposure = 0.1 * Double(i + 1)
                    case "contrast": a.contrast = 0.2
                    case "saturation": a.saturation = -0.3
                    case "temperature": a.temperature = 0.4
                    case "highlights": a.highlights = -0.5
                    default: a.shadows = 0.6
                    }
                    v.adjust = a
                }
            }
        }
        undoable(&s) { $0.changeVisual { var l = $0.look ?? E.Look(); l.grain = E.Grain(amount: 0.3); $0.look = l } }
        let c = s.selectedVideo
        XCTAssertEqual(c?.look?.strength, 0.4)
        XCTAssertEqual(c?.adjust?.shadows, 0.6)
        XCTAssertEqual(c?.look?.grain?.amount, 0.3)
        XCTAssertFalse(E.isIdentity(E.colorMatrix(c?.adjust, c?.filter)), "the colour sliders reach the render matrix")
    }

    func testMaskAndChromaControls() {
        var s = fresh()
        undoable(&s) { $0.changeVisual { $0.mask = E.Mask(shape: .circle) } }
        undoable(&s) { $0.changeMask { $0.feather = 0.4 } }
        undoable(&s) { $0.changeMask { $0.width = 0.8; $0.height = 0.8 } }
        undoable(&s) { $0.changeMask { $0.rotation = 30 } }
        undoable(&s) { $0.changeMask { $0.invert = true } }
        undoable(&s) { $0.changeMask { $0.x = 0.3; $0.y = 0.7 } }
        let m = s.selectedVideo?.mask
        XCTAssertEqual(m?.shape, .circle); XCTAssertEqual(m?.x, 0.3); XCTAssertEqual(m?.invert, true)
        // Outside the circle (and inverted: inside) the mask's alpha differs.
        XCTAssertNotEqual(E.maskAlpha(m!, 0.3, 0.7), E.maskAlpha(m!, 0.95, 0.05))
        undoable(&s) { $0.changeVisual { $0.chroma = E.Chroma(color: "#2BD15F", similarity: 0.4, smoothness: 0.08, spill: 0.5) } }
        undoable(&s) { $0.changeChroma { $0.color = "#0000FF" } }
        undoable(&s) { $0.changeChroma { $0.similarity = 0.6 } }
        undoable(&s) { $0.changeChroma { $0.smoothness = 0.2 } }
        undoable(&s) { $0.changeChroma { $0.spill = 0.1 } }
        XCTAssertEqual(s.selectedVideo?.chroma, E.Chroma(color: "#0000FF", similarity: 0.6, smoothness: 0.2, spill: 0.1))
    }

    // MARK: Audio

    func testClipSoundControlsReachTheEnvelope() throws {
        var s = fresh()
        undoable(&s) { $0.changeSound { $0.volume = 0.5 } }
        undoable(&s) { $0.changeSound { $0.fadeInSec = 1 } }
        undoable(&s) { $0.changeSound { $0.fadeOutSec = 2 } }
        undoable(&s) { $0.changeSound { $0.enhance = true } }
        undoable(&s) { $0.changeSound { $0.voiceEffect = .radio } }
        let c = try XCTUnwrap(s.selectedVideo)
        let env = E.audioEnvelope(s.project, trackId: s.project.mainTrack!.id, itemId: c.id)
        XCTAssertEqual(env.first?.gain ?? -1, 0, accuracy: 1e-6, "fade in starts silent")
        XCTAssertEqual(env.map(\.gain).max() ?? 0, 0.5, accuracy: 1e-6, "the volume")
        XCTAssertEqual(env.last?.gain ?? -1, 0, accuracy: 1e-6, "fade out ends silent")
        undoable(&s) { $0.changeSound { $0.volume = 2 } }
        XCTAssertEqual(E.audioEnvelope(s.project, trackId: s.project.mainTrack!.id, itemId: c.id).map(\.gain).max() ?? 0, 2, accuracy: 1e-6,
                       "+6 dB is a gain of 2 (the Mac's audio tap boosts above 1)")
        undoable(&s) { $0.changeSound { $0.muted = true } }
        XCTAssertTrue(E.audioEnvelope(s.project, trackId: s.project.mainTrack!.id, itemId: c.id).allSatisfy { $0.gain == 0 })
    }

    func testDuckingControls() {
        var s = fresh()
        XCTAssertTrue(s.addAudio(E.Asset(id: "a1", kind: .audio, upload: "u", durationSec: 30, hasAudio: true), kind: .music))
        XCTAssertTrue(s.addAudio(E.Asset(id: "a2", kind: .audio, upload: "v", durationSec: 3, hasAudio: true), kind: .voice, at: 4))
        undoable(&s) { $0.setAutoDuck(true) }
        undoable(&s) { $0.changeDuck { $0?.attackSec = 0.5 } }
        undoable(&s) { $0.changeDuck { $0?.releaseSec = 1 } }
        undoable(&s) { $0.changeDuck { $0?.level = EditSuite.gain(db: -20) } }
        let music = s.project.tracks.first { $0.kind == .music }!
        let env = E.audioEnvelope(s.project, trackId: music.id, itemId: music.items[0].id)
        XCTAssertEqual(gain(env, at: 5.5), EditSuite.gain(db: -20), accuracy: 1e-3, "the music dips under the voice-over")
        XCTAssertEqual(gain(env, at: 2), 1, accuracy: 1e-3, "and is back to full before it")
        undoable(&s) { $0.setAutoDuck(false) }
        XCTAssertNil(s.project.tracks.first { $0.kind == .music }?.duck)
    }

    // MARK: Captions

    private func words() -> [E.Word] {
        [("So", 0.2, 0.5), ("um", 0.6, 0.9), ("this", 1.0, 1.3), ("is", 1.35, 1.5), ("it.", 1.55, 1.9), ("Next", 4.0, 4.4), ("part", 4.5, 4.9)]
            .map { E.Word(text: $0.0, startSec: $0.1, endSec: $0.2) }
    }

    func testCaptionControls() {
        var s = fresh()
        undoable(&s) { $0.setCaptions(words: self.words(), assetId: "src") }
        XCTAssertEqual(s.project.captionTrack?.words.count, 7)
        for p in E.suiteCaptionStyles where p != s.captionStyle?.preset {
            undoable(&s) { $0.setCaptionPreset(p) }
            XCTAssertEqual(s.captionStyle?.preset, p)
        }
        undoable(&s) { $0.changeCaptionStyle { $0.font = .condensed } }
        undoable(&s) { $0.changeCaptionStyle { $0.color = "#00FF00" } }
        undoable(&s) { $0.changeCaptionStyle { $0.highlightColor = "#FF00FF" } }
        undoable(&s) { $0.changeCaptionStyle { $0.stroke = E.Stroke(color: "#111111", widthPct: 0.1) } }
        undoable(&s) { $0.changeCaptionStyle { $0.sizePct = 0.07 } }
        undoable(&s) { $0.changeCaptionStyle { $0.y = EditSuite.CaptionPosition.top.y } }
        undoable(&s) { $0.changeCaptionStyle { $0.uppercase = $0.uppercase == true ? nil : true } }
        XCTAssertEqual(s.captionStyle?.y, 0.2)
        XCTAssertEqual(s.captionStyle?.font, .condensed)
        undoable(&s) { $0.editWord(2, text: "that") }
        XCTAssertEqual(s.project.captionTrack?.words[2].text, "that")
    }

    func testEditByTextFillersAndSilences() {
        var s = fresh()
        XCTAssertTrue(s.setCaptions(words: words(), assetId: "src"))
        XCTAssertEqual(s.fillerCuts.count, 1)
        undoable(&s) { $0.applyCuts($0.fillerCuts, assetId: "src") }
        XCTAssertLessThan(s.duration, 10)
        XCTAssertFalse(s.transcript().first { $0.text == "um" }!.kept)
        let d = s.duration
        XCTAssertFalse(s.silenceCuts().isEmpty, "the 2.1 s pause after \"it.\"")
        undoable(&s) { $0.applyCuts($0.silenceCuts(), assetId: "src") }
        XCTAssertLessThan(s.duration, d - 1.5)
        undoable(&s) { $0.deleteWords([6]) }
        XCTAssertFalse(s.transcript().first { $0.text == "part" }!.kept)
    }

    // MARK: Animate

    func testInAndOutAnimations() {
        var s = fresh()
        s.playhead = 1
        XCTAssertTrue(s.addText("anim"))
        undoable(&s) { $0.changeSelected { it in if case .text(var x) = it { x.animIn = E.Anim(kind: .slideUp, durationSec: 0.5); it = .text(x) } } }
        undoable(&s) { $0.changeSelected { it in if case .text(var x) = it { x.animOut = E.Anim(kind: .typewriter, durationSec: 1); it = .text(x) } } }
        let tx = s.selectedItem!.textItem!
        XCTAssertEqual(tx.animIn?.kind, .slideUp)
        XCTAssertLessThan(E.placement(tx, local: 0.1).opacity, 1, "the slide-up fades in")
    }
}

extension EditSuiteControlsTests {
    func testTranslateCaptionsKeepsTimingAndCuts() {
        var s = EditSuiteState(EditV2.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 10), EditV2.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        XCTAssertTrue(s.setCaptions(words: [("Hello", 0.2, 0.6), ("there.", 0.7, 1.2), ("How", 3.0, 3.3), ("are", 3.4, 3.6), ("you?", 3.7, 4.1)]
            .map { EditV2.Word(text: $0.0, startSec: $0.1, endSec: $0.2) }, assetId: "src"))
        XCTAssertEqual(s.captionChunks.map(\.text), ["Hello there.", "How are you?"])
        let before = s.project
        XCTAssertTrue(s.translateCaptions(["Hola.", "¿Cómo estás tú?"]))
        let w = s.project.captionTrack!.words
        XCTAssertEqual(w.map(\.text), ["Hola.", "¿Cómo", "estás", "tú?"])
        XCTAssertEqual(w.first!.startSec, 0.2, accuracy: 1e-6)
        XCTAssertEqual(w[1].startSec, 3.0, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(w.last!.endSec, 4.1 + 1e-6)
        XCTAssertNil(EditV2.problem(s.project))
        XCTAssertFalse(s.translateCaptions(["only one"]), "chunk count must match")
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.project, before)
    }
}
